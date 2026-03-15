#  app.psgi  -  A simple proxy for making cross-domain requests
#  Part of CList, the next generation of learning and connecting with your community
#
#  Version 0.2 — rewritten as Plack/PSGI app
#
#  Copyright National Research Council of Canada 2025
#  Licensed under Creative Commons Attribution 4.0 International https://creativecommons.org/licenses/by/4.0/
#
#  This software carries NO WARRANTY OF ANY KIND.
#  This software is provided "AS IS," and you, its user, assume all risks when using it.

use strict;
use warnings;
use LWP::UserAgent;
use URI;
use URI::Escape qw(uri_escape);
use Plack::Request;

my $ua = LWP::UserAgent->new(timeout => 15);

# Return a JSON error response (always 200 so the client JS sees the body)
sub json_error {
    my ($msg) = @_;
    (my $safe = $msg) =~ s/"/\\"/g;
    return [200,
        [cors_headers()],
        [qq|{"error":"$safe"}|]];
}

sub cors_headers {
    return (
        'Content-Type'                 => 'application/json',
        'Access-Control-Allow-Origin'  => '*',
        'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers' => 'Content-Type',
    );
}

# Accept only http(s) URLs with a proper hostname — no bare IPs, no localhost
sub validate_url {
    my ($url) = @_;
    return 0 unless defined $url;
    return 0 unless $url =~ m{^https?://([a-zA-Z0-9][a-zA-Z0-9\-]*(?:\.[a-zA-Z0-9][a-zA-Z0-9\-]*)*\.[a-zA-Z]{2,})}i;
    my $host = $1;
    return 0 if $host =~ /^localhost$/i;
    return 0 if $host =~ /^\d+\.\d+\.\d+\.\d+$/;  # no raw IPv4 addresses
    return 1;
}

my $app = sub {
    my $env   = shift;
    my $req    = Plack::Request->new($env);
    my $method = $env->{REQUEST_METHOD};

    # CORS preflight
    if ($method eq 'OPTIONS') {
        return [204, [cors_headers()], []];
    }

    if ($method eq 'GET') {
        my $url = $req->param('url');
        unless ($url) {
            warn "[proxyp] GET missing url parameter\n";
            return json_error("Missing 'url' parameter");
        }
        unless (validate_url($url)) {
            warn "[proxyp] GET rejected url: $url\n";
            return json_error("Invalid 'url' parameter");
        }

        # Forward all query params except 'url' itself (was a bug in v0.1)
        my %params = %{ $req->parameters };
        delete $params{url};

        my $uri = URI->new($url);
        $uri->query_form(%params) if %params;

        warn "[proxyp] GET $uri\n";
        my $res = $ua->get($uri);
        if ($res->is_success) {
            return [200, [cors_headers()], [$res->decoded_content]];
        }
        warn "[proxyp] GET upstream error: " . $res->status_line . "\n";
        return json_error("Request failed: " . $res->status_line);

    } elsif ($method eq 'POST') {
        my %params = %{ $req->parameters };
        my $url = delete $params{url};
        unless ($url) {
            warn "[proxyp] POST missing url parameter\n";
            return json_error("Missing 'url' parameter");
        }
        unless (validate_url($url)) {
            warn "[proxyp] POST rejected url: $url\n";
            return json_error("Invalid 'url' parameter");
        }

        my $post_data = join('&',
            map { uri_escape($_) . '=' . uri_escape($params{$_}) } keys %params);

        warn "[proxyp] POST $url\n";
        my $res = $ua->post($url, Content => $post_data);
        if ($res->is_success) {
            return [200, [cors_headers()], [$res->decoded_content]];
        }
        warn "[proxyp] POST upstream error: " . $res->status_line . "\n";
        return json_error("Request failed: " . $res->status_line);

    } else {
        return json_error("Unsupported HTTP method: $method");
    }
};

$app;
