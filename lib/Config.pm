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


package Bugzilla::Extension::BitCoin::Config;
use strict;
use warnings;

use Bugzilla::Config::Common;

sub get_param_list {
    my ($class) = @_;

    my @param_list = (
    {
        name => 'bitcoinsiteaddress',
        type => 't',
        default => '14k1Rmog9RmogUrvmQA9HpyDRdypNzANwK',
    },
    {
        name => 'bitcoinhostaddress',
        type => 't',
        default => 'localhost:8332',
    },
    {
        name => 'bitcoinrpcusername',
        type => 't',
        default => '',
    },
    {
        name => 'bitcoinrpcpassword',
        type => 't',
        default => '',
    },

    {
        name => 'bitcoinpercentproject',
        type => 't',
        default => '20',
    },

    {
        name => 'bitcoinpercentdonate',
        type => 't',
        default => '5',
    },



    );
    return @param_list;
}

1;
