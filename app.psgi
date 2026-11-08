#  app.psgi  -  A simple proxy for making cross-domain requests
#  Part of CList, the next generation of learning and connecting with your community
#
#  Version 0.5 — added admin-declarable access key for unauthenticated use
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
use JSON::PP qw(encode_json decode_json);

my $ua = LWP::UserAgent->new(timeout => 15);
my $kvstore_url = $ENV{KVSTORE_URL} || 'http://kvstore:5000';
my $data_dir = $ENV{DATA_DIR} || '/app/data';
my $settings_file = "$data_dir/settings.json";

# In-memory token cache: token => expiry epoch (5-minute TTL)
my %token_cache;
my $CACHE_TTL = 300;

sub verify_token {
    my ($token) = @_;
    my $now = time();
    return 1 if exists $token_cache{$token} && $token_cache{$token} > $now;

    # Call kvstore to validate
    my $res = $ua->get("$kvstore_url/auth/verify",
        'Authorization' => "Bearer $token");

    if ($res->is_success) {
        $token_cache{$token} = $now + $CACHE_TTL;
        return 1;
    }
    delete $token_cache{$token};
    return 0;
}

# Same kvstore call as verify_token(), but for the admin-settings gate, which
# needs the username (not just a yes/no) to check against ADMIN_USERNAMES —
# done as a separate, uncached call since admin-settings traffic is rare.
sub verify_token_get_username {
    my ($token) = @_;
    my $res = $ua->get("$kvstore_url/auth/verify",
        'Authorization' => "Bearer $token");
    return undef unless $res->is_success;
    my $data = eval { decode_json($res->decoded_content) };
    return ($data && $data->{username}) ? $data->{username} : undef;
}

# Returns ($username, undef) on success, or (undef, $plack_response) on failure —
# caller does `my ($username, $err) = require_admin($env); return $err if $err;`
sub require_admin {
    my ($env) = @_;
    my $auth = $env->{HTTP_AUTHORIZATION} // '';
    my ($token) = ($auth =~ /^Bearer\s+(\S+)$/i);
    unless ($token) {
        return (undef, [401, [cors_headers()], ['{"error":"Authorization header required"}']]);
    }
    my $username = verify_token_get_username($token);
    unless ($username) {
        return (undef, [401, [cors_headers()], ['{"error":"Invalid or expired token"}']]);
    }
    my @admins = grep { length } map { s/^\s+|\s+$//g; $_ } split /,/, ($ENV{ADMIN_USERNAMES} // '');
    unless (grep { $_ eq $username } @admins) {
        warn "[proxyp] Admin settings: rejected non-admin user $username\n";
        return (undef, [403, [cors_headers()], ['{"error":"Forbidden"}']]);
    }
    return ($username, undef);
}

# ---- Settings (ENABLED / ACCESS_KEY), flat JSON file on a bind-mounted volume ----

sub load_settings {
    if (-f $settings_file) {
        open my $fh, '<', $settings_file or return { ENABLED => JSON::PP::false, ACCESS_KEY => '' };
        local $/;
        my $json = <$fh>;
        close $fh;
        my $data = eval { decode_json($json) };
        return $data if $data;
    }
    return { ENABLED => JSON::PP::false, ACCESS_KEY => '' };
}

sub save_settings {
    my ($settings) = @_;
    mkdir $data_dir unless -d $data_dir;
    open my $fh, '>', $settings_file or die "[proxyp] Cannot write settings file: $!";
    print $fh encode_json($settings);
    close $fh;
}

# Schema served by GET/PUT /admin/settings — same {key,label,type,sensitive,help}
# shape as the clist-server-admin package's SettingField, so CList's generic
# App Settings panel renders this with no special-casing.
my @SETTINGS_SCHEMA = (
    {
        key => 'ENABLED', label => 'Enable unauthenticated access', type => 'boolean', sensitive => JSON::PP::false,
        help => 'When on, a request carrying the correct access key is treated as authorized (same as a valid login token), without requiring one.',
    },
    {
        key => 'ACCESS_KEY', label => 'Access key', type => 'text', sensitive => JSON::PP::false,
        help => 'Shared value CList sends automatically to use this feature while logged out. Not a true secret — it is published via GET /public-key for logged-out CList sessions to read, so anyone who inspects network traffic or that endpoint can see it. Useful for instant revocation/rotation if abused, not for confidentiality.',
    },
);

sub handle_public_key {
    my $settings = load_settings();
    if ($settings->{ENABLED} && length($settings->{ACCESS_KEY} // '')) {
        return [200, [cors_headers()], [encode_json({ enabled => JSON::PP::true, key => $settings->{ACCESS_KEY} })]];
    }
    return [200, [cors_headers()], [encode_json({ enabled => JSON::PP::false })]];
}

sub handle_admin_settings {
    my ($env, $req, $method) = @_;

    if ($method eq 'GET') {
        my ($username, $err) = require_admin($env);
        return $err if $err;
        my $settings = load_settings();
        return [200, [cors_headers()], [encode_json({ schema => \@SETTINGS_SCHEMA, values => $settings })]];

    } elsif ($method eq 'PUT') {
        my ($username, $err) = require_admin($env);
        return $err if $err;
        my $body = eval { decode_json($req->content || '{}') };
        unless ($body) {
            return [400, [cors_headers()], ['{"error":"Invalid JSON body"}']];
        }
        my $settings = load_settings();
        if (exists $body->{ENABLED}) {
            $settings->{ENABLED} = $body->{ENABLED} ? JSON::PP::true : JSON::PP::false;
        }
        if (exists $body->{ACCESS_KEY}) {
            $settings->{ACCESS_KEY} = defined($body->{ACCESS_KEY}) ? "$body->{ACCESS_KEY}" : '';
        }
        save_settings($settings);
        warn "[proxyp] Admin settings updated by $username\n";
        return [200, [cors_headers()], [encode_json({ schema => \@SETTINGS_SCHEMA, values => $settings })]];

    } else {
        return [405, [cors_headers()], ['{"error":"Method not allowed"}']];
    }
}

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
        'Access-Control-Allow-Methods' => 'GET, POST, PUT, OPTIONS',
        'Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-Access-Key',
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
    my $path   = $env->{PATH_INFO} || '/';

    # CORS preflight
    if ($method eq 'OPTIONS') {
        return [204, [cors_headers()], []];
    }

    # Deliberately public — see SETTINGS_SCHEMA's ACCESS_KEY help text for why
    # this can't be kept secret in a 100%-client-side-JS consumer like CList.
    if ($path eq '/public-key') {
        return handle_public_key();
    }

    if ($path eq '/admin/settings') {
        return handle_admin_settings($env, $req, $method);
    }

    # Require either a valid kvstore Bearer token, or the admin-declared access
    # key (X-Access-Key header) while that bypass is enabled — see "Kill switch"
    # in /srv/apps/proxyp/CLAUDE.md for the security tradeoff this accepts.
    my $settings = load_settings();
    my $access_key_header = $env->{HTTP_X_ACCESS_KEY} // '';
    my $key_ok = $settings->{ENABLED}
        && length($settings->{ACCESS_KEY} // '')
        && $access_key_header eq $settings->{ACCESS_KEY};

    if ($key_ok) {
        warn "[proxyp] Authorized via access key\n";
    } else {
        my $auth = $env->{HTTP_AUTHORIZATION} // '';
        my ($token) = ($auth =~ /^Bearer\s+(\S+)$/i);
        unless ($token && verify_token($token)) {
            warn "[proxyp] Unauthorized request\n";
            return [401, [cors_headers()], ['{"error":"Unauthorized"}']];
        }
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
            # Pass through the upstream response's real content type instead of
            # cors_headers()'s hardcoded JSON default — GET relays return arbitrary
            # HTML/XML/text, and callers (e.g. CList's "Load from URL") need the
            # real type to detect format.
            my @headers = cors_headers();
            my $upstream_ct = $res->header('Content-Type');
            if ($upstream_ct) {
                for (my $i = 0; $i < @headers; $i += 2) {
                    $headers[$i + 1] = $upstream_ct if $headers[$i] eq 'Content-Type';
                }
            }
            return [200, \@headers, [$res->decoded_content]];
        }
        warn "[proxyp] GET upstream error: " . $res->status_line . "\n";
        return json_error("Request failed: " . $res->status_line);

    } elsif ($method eq 'POST') {
        # A multipart/form-data POST carrying a file upload (e.g. relaying an Etherpad
        # "/import" request) needs a different relay path than the flat url-encoded
        # params below — Plack::Request parses multipart bodies automatically, so
        # detect a 'file' upload field and branch before touching the existing logic.
        my $uploads = $req->uploads;
        if ($uploads && $uploads->get('file')) {
            my $url = $req->param('url');
            unless ($url) {
                warn "[proxyp] POST multipart missing url parameter\n";
                return json_error("Missing 'url' parameter");
            }
            unless (validate_url($url)) {
                warn "[proxyp] POST multipart rejected url: $url\n";
                return json_error("Invalid 'url' parameter");
            }

            my $upload = $uploads->get('file');
            my $filename = $upload->filename || 'upload';
            my $contentType = $upload->content_type || 'application/octet-stream';

            open my $fh, '<', $upload->path
                or return json_error("Could not read uploaded file");
            binmode $fh;
            my $filedata = do { local $/; <$fh> };
            close $fh;

            warn "[proxyp] POST multipart relay to $url (file: $filename, $contentType, "
                . length($filedata) . " bytes)\n";

            my $res = $ua->post($url,
                Content_Type => 'form-data',
                Content => [ file => [ undef, $filename, Content_Type => $contentType, Content => $filedata ] ],
            );

            if ($res->is_success) {
                return [200, [cors_headers()], [$res->decoded_content]];
            }
            warn "[proxyp] POST multipart upstream error: " . $res->status_line . "\n";
            return json_error("Request failed: " . $res->status_line);
        }

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
