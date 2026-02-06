package Koha::Plugin::Com::Biblibre::Electre::Controller::Webservice;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use LWP::UserAgent;
use LWP::Authen::OAuth2;
use HTTP::Request::Common;
use JSON;

use C4::Context;
use C4::Koha qw(NormalizeISBN);

=head1 API

=head2 Methods

Controller function that handles getting Electre images

=cut

sub get_electre_image {
    my $c = shift->openapi->valid_input or return;

    my $isbn10 = $c->param('isbn10');
    
    return $c->render(
        status => 400,
        openapi => { error => "No ISBN10 provided" }
    ) unless $isbn10;
    
    my $ean = NormalizeISBN(
            {
                isbn          => $isbn10,
                format        => 'ISBN-13',
                strip_hyphens => 1,
            }
        );
    return $c->render(
        status => 400,
        openapi => { error => "Invalid ISBN10: could not convert to EAN13" }
    ) unless $ean;

    my $side           = $c->param('side');
    my $on_result_page = $c->param('result_page');
    my $picSize        = $c->_determine_pic_size( $c, $side, $on_result_page );

    my $token = $c->_getAccessToken();

    my $noticeByEanEndpoint = "https://api.electre-ng.com/notices/ean/${ean}";

    my $request = HTTP::Request::Common::GET(
        $noticeByEanEndpoint,
        Authorization  => $token,
        "Content-Type" => "application/json"
    );

    my $response = _request($request);
    if ( $response->is_success ) {
        my $contents = from_json( $response->decoded_content )->{"notices"}[0];
        my $picUrl   = $contents->{$picSize};

        if (!$picUrl) {
            return $c->render(
                status => 404,
                openapi => { error => "No cover image found for this ISBN" }
            );
        }

        return $c->render(
            status => 200,
            data   => $picUrl,
        );
    }
    elsif ( $response->code == 404 ) {
        return $c->render(
            status => 404,
            openapi => { error => "No notice found for this ISBN" }
        );
    }
    elsif ( $response->is_error ) {
        return $c->render(
            status  => 500,
            openapi =>
              { error => "Electre error: " . $response->status_line },
        );
    }
}

sub get_electre_resume {
    my $c = shift->openapi->valid_input or return;

    my $isbn10 = $c->param('isbn10');
    
    return $c->render(
        status => 400,
        openapi => { error => "No ISBN10 provided" }
    ) unless $isbn10;
    
    my $ean = NormalizeISBN(
            {
                isbn          => $isbn10,
                format        => 'ISBN-13',
                strip_hyphens => 1,
            }
        );
    return $c->render(
        status => 400,
        openapi => { error => "Invalid ISBN10: could not convert to EAN13" }
    ) unless $ean;

    my $token               = $c->_getAccessToken();
    my $noticeByEanEndpoint = "https://api.electre-ng.com/notices/ean/${ean}";

    my $request = HTTP::Request::Common::GET(
        $noticeByEanEndpoint,
        Authorization  => $token,
        "Content-Type" => "application/json"
    );

    my $response = _request($request);
    if ( $response->is_success ) {
        my $contents = from_json( $response->decoded_content )->{"notices"}[0];
        my $resume   = $contents->{'quatriemeDeCouverture'};

        if (!$resume) {
            return $c->render(
                status => 404,
                openapi => { error => "No resume found for this ISBN" }
            );
        }

        return $c->render(
            status => 200,
            data   => $resume,
        );
    }
    elsif ( $response->code == 404 ) {
        return $c->render(
            status => 404,
            openapi => { error => "No notice found for this ISBN" }
        );
    }
    elsif ( $response->is_error ) {
        return $c->render(
            status  => 500,
            openapi =>
              { error => "Electre error: " . $response->status_line },
        );
    }
}

sub _getAccessToken {
    my ($self) = @_;

    my $cache;

    eval { $cache = Koha::Caches->get_instance() };
    if ($@) {
        warn "Could not get cache: $@";
    }

    my $token;
    $cache
      and $token = $cache->get_from_cache("ElectreAuthentificationToken")
      and return $token;

    my $plugin = Koha::Plugin::Com::Biblibre::Electre->new();

    my $username = $plugin->retrieve_data('access_username');
    my $password = $plugin->retrieve_data('access_password');

    my $accessTokenEndpoint =
'https://login.electre-ng.com/auth/realms/electre/protocol/openid-connect/token';

    my $request = HTTP::Request::Common::POST(
        $accessTokenEndpoint,
        [
            grant_type => 'password',
            client_id  => 'api-client',
            username   => $username,
            password   => $password,
        ]
    );

    my $response = _request($request);

    my $contents = from_json( $response->decoded_content );

    $token = $contents->{'token_type'} . ' ' . $contents->{'access_token'};

    $cache
      and $cache->set_in_cache( 'ElectreAuthentificationToken',
        $token, { expiry => $contents->{'expires_in'} - 5 } );

    return $token;
}

sub _request {
    my ($request) = @_;
    my $ua = LWP::UserAgent->new( agent => "Koha " . $Koha::VERSION );
    $ua->timeout(5); # Set timeout to improve perf 	

    my $response;
    eval { $response = $ua->request($request); };
    if ($@) {
        warn "Request failed: $@";
        return;
    }

    return $response;
}

sub _isThumbnailSize {
    my ( $self, $side ) = @_;

    my $plugin = Koha::Plugin::Com::Biblibre::Electre->new();

    return $plugin->retrieve_data("thumbnail_on_$side");
}

sub _determine_pic_size {
    my ( $self, $c, $side, $on_result_page ) = @_;

    if ($on_result_page) {
        return 'imagetteCouverture';
    }
    else {
        return $c->_isThumbnailSize($side)
          ? 'imagetteCouverture'
          : 'imageCouverture';
    }
}

1;
