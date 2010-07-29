# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the BitCoin Bugzilla Extension.
#
# The Initial Developer of the Original Code is Mark Bryars
# Portions created by the Initial Developer are Copyright (C) 2010 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Mark Bryars <bugzilla@darkskiez.co.uk>


package Bugzilla::Extension::BitCoin;
use strict;
use base qw(Bugzilla::Extension);
use Bugzilla::Template qw(get_attachment_link);
use Bugzilla::Constants;
use Bugzilla::Field;
use Bugzilla::Config qw(SetParam write_params);

use Data::Dumper;

use JSON::RPC::Client;

use constant DONATE_ADDRESS => '1ENjWt9mB8as5Kom8SwUwXiUDKGrAxQhBC';
use constant MINIMUM_CONFIRMATIONS => 1;

our $VERSION = '0.1';

# uninstall
# alter table bugs drop column bitcoin;
# delete from fielddefs where name='bitcoin';


sub new 
{
    my ($class, %params) = @_;
    my $self = $class->SUPER::new(%params); 

    $self->bitcoin_prepare();

    return $self;
}


sub assign_pending_addresses
{
    my ($self, $args) = @_;
     
    my $dbh = Bugzilla->dbh;
    my $sth = $dbh->prepare("SELECT bug_id FROM bugs WHERE bitcoin_address IS NULL");
    $sth->execute();

    eval
    {
        while (my ($bug_id) = $sth->fetchrow_array())
        {
            $self->update_bug_address($bug_id);
        }
        1;
    }
    or do
    {
        warn "Failed Bitcoin Magic $@";
    }

}

sub update_all
{
    my ($self, $args) = @_;
     
    my $dbh = Bugzilla->dbh;
    my $sth = $dbh->prepare("SELECT bug_id FROM bugs WHERE bitcoin_address IS NOT NULL");
    $sth->execute();
 
    eval
    {
        while (my ($bug_id) = $sth->fetchrow_array()) 
        {
            $self->update_bug_balance($bug_id);
        }
        1;
    }
    or do
    {
        warn "Failed Bitcoin Magic $@";
        return 0;
    }

}


sub bitcoin_prepare 
{
    my ($self, $args) = @_;
    my $client = new JSON::RPC::Client;
    my $uri = "http://" . Bugzilla->params->{'bitcoinhostaddress'};
    $client->prepare($uri, ['getinfo', 'getnewaddress', 'getreceivedbylabel','sendtoaddress']);
    $client->ua->credentials(Bugzilla->params->{'bitcoinhostaddress'},
                             'jsonrpc',
                             '', #Bugzilla->params->{'bitcoinrpcusername'},
                             Bugzilla->params->{'bitcoinrpcpassword'});

    $self->{_client} = $client;
}





sub update_bug_address 
{
    my ($self, $bug_id) = @_;
 
    my $bitcoin_address= $self->{_client}->getnewaddress("bug:".$bug_id);

    if ( $bitcoin_address =~ /([a-zA-Z0-9]*)/) 
    {
        $bitcoin_address = $1;

        my $dbh = Bugzilla->dbh;
        $dbh->do("UPDATE bugs
                SET bitcoin_address = '$bitcoin_address'
                WHERE bug_id = $bug_id");
    }
    else
    {
        warn "Invalid address from bitcoin client: $bitcoin_address"
    }
    
}

# Read Current Balance
# Read New Balance
# Calculate Received Amount
# 
# Send % of received amount to site 
# Send % of received amount as donation
# Increment bitcoins_sent

# TODO:
#
# If Closed > timelimit
# Send % remaining to qa id
# Send remaining to developer id
# Increment bitcoints_sent


sub update_bug_balance
{
    my ($self, $bug_id) = @_;
    my $prev_received;
    my $prev_paid;
    my $bitcoins_received;
  
    # Validate BugID

    if ( $bug_id =~ /([0-9]+)/) 
    {
        $bug_id = $1;
    }
    else
    {
        warn "ERROR: Invalid BUG_ID $bug_id";
        return;
    }
   

    # Collect New Balance

    $bitcoins_received = $self->{_client}->getreceivedbylabel("bug:".$bug_id, MINIMUM_CONFIRMATIONS);
    if ( $bitcoins_received =~ /([0-9.]*)/) 
    {
        $bitcoins_received = $1;
    }
    else
    {
        warn "ERROR: BitCoin returned invalid amount: $bitcoins_received";
        return;
    }
    
    # Compare against DB

    my $dbh = Bugzilla->dbh;

    my $sth = $dbh->prepare("SELECT bitcoins_received, bitcoins_paid
            FROM bugs
            WHERE bug_id = $bug_id");
    $sth->execute();
    if (!(($prev_received, $prev_paid) = $sth->fetchrow_array())) 
    {
        warn "database error in bitcoin - retreiving bug_id: $bug_id";
        return;
    }

    if ($prev_received == $bitcoins_received)
    {
        return;
    }

    #warn "$prev_received != $bitcoins_received";

    # Action Needed

    my $donate_pct = Bugzilla->params->{'bitcoinpercentdonate'};
    my $project_pct = Bugzilla->params->{'bitcoinpercentproject'};

    # Validate DB Params

    if ($donate_pct < 0)
    {
        $donate_pct=0;
        SetParam('bitcoinpercentdonate','0');
        write_params();
    }
    if ($project_pct < 0)
    {
        $project_pct=0;
        SetParam('bitcoinpercentproject','0');
        write_params();
    }
    if (($donate_pct + $project_pct)>100) 
    {
        $donate_pct = $donate_pct/($donate_pct + $project_pct)*100;
        $project_pct = 100-$donate_pct;
        warn "BitCoin Distribution Percentages didnt add up - normalising";
        SetParam('bitcoinpercentdonate',$donate_pct);
        SetParam('bitcoinpercentproject',$project_pct);
        write_params();
    }

    my $bcs = $bitcoins_received-$prev_received;
     
    # Calculate Split
    my $project_portion = $bcs*$project_pct/100;
    my $donate_portion = $bcs*$donate_pct/100;

    $project_portion = 0 if ($project_portion < 0.01);
    $donate_portion = 0 if ($donate_portion < 0.01);

    # Check For Cancelled/Invalid Txns
    if ($prev_received > $bitcoins_received) 
    {
        warn "WARNING: BitCoins Received Have REDUCED! $bug_id from $prev_received to $bitcoins_received";
        $dbh->do("UPDATE bugs
                SET bitcoins_received = $bitcoins_received
                WHERE bug_id = $bug_id");
        return;
    }
   
    # if we would pay out more than we received, stop bug from happening
    if (($prev_paid + $project_portion + $donate_portion) > $bitcoins_received)
    {
        warn "WARNING: BitCoins Payment Error Previous:$prev_paid New: $bitcoins_received (Project: $project_portion Donate: $donate_portion)";
        $dbh->do("UPDATE bugs
                SET bitcoins_received = $bitcoins_received
                WHERE bug_id = $bug_id");
        return;
    }

    my $project_add = Bugzilla->params->{'bitcoinsiteaddress'};
    
    warn "INFO: Bitcoin BUG: $bug_id Received $bcs Project $project_portion Donate $donate_portion ";
   
    if ($donate_portion > 0) 
    {
        $self->{_client}->sendtoaddress(DONATE_ADDRESS, $donate_portion+0);
    }
    if ($project_portion > 0)
    {
        $self->{_client}->sendtoaddress($project_add, $project_portion+0);
    }

    $dbh->do("UPDATE bugs
            SET bitcoins_received = $bitcoins_received,
            bitcoins_paid = (bitcoins_paid + $project_portion + $donate_portion) 
            WHERE bug_id = $bug_id");


# $send_results project_add

}

################# Bugzilla Hooks

## DB Install

sub install_update_db 
{
    my ($self, $args) = @_;
    
    my $dbh = Bugzilla->dbh;
 
#    $dbh->bz_drop_column("bugs", "bitcoin_address");
#    $dbh->bz_drop_column("bugs", "bitcoins_received");

    if (!$dbh->bz_column_info('bugs', 'bitcoin_address')) 
    {
        $dbh->bz_add_column('bugs', 'bitcoin_address', {TYPE => 'varchar(255)'});
    }
 
    if (! $dbh->bz_column_info('bugs', 'bitcoins_received')) 
    {
        $dbh->bz_add_column('bugs', 'bitcoins_received', {TYPE => 'decimal(8,2)', NOTNULL => 1, DEFAULT => '0'});
    }

    if (! $dbh->bz_column_info('bugs', 'bitcoins_paid')) 
    {
        $dbh->bz_add_column('bugs', 'bitcoins_paid', {TYPE => 'decimal(8,2)', NOTNULL => 1, DEFAULT => '0'});
    }
 
    if (! $dbh->bz_column_info('profiles', 'bitcoins_due')) 
    {
        $dbh->bz_add_column('profiles', 'bitcoins_due', {TYPE => 'decimal(8,2)', NOTNULL => 1, DEFAULT => '0'});
    }  

    #if (! $dbh->bz_column_info('profiles', 'bitcoin_address')) 
    #{
    #    $dbh->bz_add_column('profiles', 'bitcoin_address', {TYPE => 'varchar(255)', NOTNULL => 1, DEFAULT => '0'});
    #}  

    my $sth = $dbh->prepare("SELECT id FROM fielddefs WHERE name = 'bitcoin_address'");
    $sth->execute();
    if (! $sth->fetchrow_array()) 
    {
        my $field = Bugzilla::Field->create({
                name        => "bitcoin_address",
                description => "BitCoin Address",
                type        => FIELD_TYPE_FREETEXT,
                mailhead    => 0,
                enter_bug   => 0,
                obsolete    => 0, 
                custom      => 0,
                buglist     => 1,
                });
    }

    $sth = $dbh->prepare("SELECT id FROM fielddefs WHERE name = 'bitcoins_received'");
    $sth->execute();
    if (! $sth->fetchrow_array()) 
    {
        my $field = Bugzilla::Field->create({
                name        => "bitcoins_received",
                description => "BitCoins Received",
                type        => FIELD_TYPE_UNKNOWN,
                mailhead    => 0,
                enter_bug   => 0,
                obsolete    => 0, 
                custom      => 0,
                buglist     => 1,
                });
    }

}

## Bitcoin Pages

sub page_before_template 
{
    my ($self, $args) = @_;

    my ($vars, $page) = @$args{qw(vars page_id)};
    my $dbh = Bugzilla->dbh;

    # page.cgi?id=bitcoin.html

    if ($page eq 'bitcoin.html') 
    {

        eval 
        {
            my $info = $self->{_client}->getinfo();
            $vars->{info} = $info;
            1;
        }
        or do
        {
            $vars->{error} = "$@"; 
            $vars->{page_id} = "error.html";
        }
    }
    elsif ($page eq 'bitcoin-update.html') 
    {
        $self->update_all();
    }

}


sub template_before_create 
{
    my ($self, $args) = @_;

    my $config = $args->{'config'};
#    $config->{VARIABLES}->{example_global_variable} = sub { return 'value' };

}

sub template_before_process 
{
    my ($self, $args) = @_;

    my ($vars, $file, $context) = @$args{qw(vars file context)};
    
    my $dbh = Bugzilla->dbh;
    my $cgi = Bugzilla->cgi;
    my $user = Bugzilla->user;

    if ($file eq 'account/prefs/account.html.tmpl')
    {
        my $sth = $dbh->prepare("SELECT bitcoins_due FROM profiles WHERE userid = ".$user->id);
        my $bitcoins_due;
        $sth->execute();
        if (! ($bitcoins_due = $sth->fetchrow_array())) 
        {
            warn "database error in bitcoin - retreiving bitcoins_due from user: ".$user->id;
            return;
        }
       
        $vars->{bitcoins_due} = $bitcoins_due;

        if ($cgi->param('usersbitcoinaddress'))
        {
            #TODO: Send DUE
        }

    }
    elsif ($file eq 'bug/show.html.tmpl')
    {
        my $bug = $cgi->param('id');
        eval 
        {
            $self->update_bug_balance($bug);
            1;
        } 
        or do
        {
            warn "Failed Bitcoin Magic $@";
        }

    }

    #warn "Bugzilla PAGE: $file";
}



## Sanity Check Hooks

sub sanitycheck_check 
{
    my ($self, $args) = @_;

    my $dbh = Bugzilla->dbh;
    my $sth;

    my $status = $args->{'status'};

    $status->('bitcoin_check_schema');
    $self->install_update_db();
     
}

sub sanitycheck_repair 
{
    my ($self, $args) = @_;

    my $cgi = Bugzilla->cgi;
    my $dbh = Bugzilla->dbh;

    my $status = $args->{'status'};

}


## Bug Editing Hooks

sub bug_end_of_create 
{
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
   
    eval 
    {
        $self->update_bug_address($bug->id);
        1;
    } 
    or do
    {
        warn "Failed Bitcoin Magic $@";
    }

}

sub bug_end_of_update 
{
    my ($self, $args) = @_;
    
    my ($bug, $old_bug, $timestamp, $changes) =
        @$args{qw(bug old_bug timestamp changes)};

    eval 
    {
        $self->update_bug_address($bug->id);
        $self->update_bug_balance($bug->id);
        1;
    } 
    or do
    {
        warn "Failed Bitcoin Magic $@";
    }
}


## Bug Management Hooks

sub bug_columns 
{
    my ($self, $args) = @_;
    my $columns = $args->{'columns'};
    
    push (@$columns, "bitcoin_address");
    push (@$columns, "bitcoins_received");

}

sub bug_fields 
{
    my ($self, $args) = @_;

    my $fields = $args->{'fields'};
    push (@$fields, "bitcoin_address");
    push (@$fields, "bitcoins_received");
}

sub buglist_columns 
{
    my ($self, $args) = @_;

    my $columns = $args->{'columns'};
    $columns->{'bitcoin_address'} = { 'name' => 'bitcoin_address' , 'title' => 'BitCoin Address' };
    $columns->{'bitcoins_received'} = { 'name' => 'bitcoins_received' , 'title' => 'BitCoins Received' };
}

sub colchange_columns 
{
    my ($self, $args) = @_;

    my $columns = $args->{'columns'};
    push (@$columns, "bitcoin_address");
    push (@$columns, "bitcoins_received");
}


## Configuration Hooks

sub config_add_panels 
{
    my ($self, $args) = @_;

    my $modules = $args->{panel_modules};
    $modules->{BitCoin} = "Bugzilla::Extension::BitCoin::Config";
}

__PACKAGE__->NAME;
