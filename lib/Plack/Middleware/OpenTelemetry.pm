package Plack::Middleware::OpenTelemetry;

# ABSTRACT: Plack middleware to setup OpenTelemetry tracing

use strict;
use warnings;
use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(attributes);
use OpenTelemetry::Constants qw( SPAN_KIND_SERVER SPAN_STATUS_ERROR SPAN_STATUS_OK );
use Syntax::Keyword::Dynamically;

sub prepare_app {
    my $self = shift;

    unless ($self->attributes) {
        $self->attributes({});
    }

}

sub call {
    my ($self, $env) = @_;

    my $provider = OpenTelemetry->tracer_provider;
    return $self->app->($env) unless $provider;

    my $attributes = $self->attributes;
    my $tracer     = $provider->tracer(%$attributes);
    return $self->app->($env) unless ($tracer);

    my $span = $tracer->create_span(
        name       => "request",
        kind       => SPAN_KIND_SERVER,
        attributes => {
            "url.path"      => $env->{PATH_INFO},
            "plack.version" => "$Plack::VERSION",
        },
    );

    dynamically OpenTelemetry::Context->current = OpenTelemetry::Trace->context_with_span($span);

    $span->set_attribute("http.scheme",
        $env->{HTTP_X_FORWARDED_PROTO} || $env->{"psgi.url_scheme"});

    $span->set_attribute("http.client_ip",  $env->{REMOTE_ADDR});
    $span->set_attribute("http.target",     $env->{REQUEST_URI});
    $span->set_attribute("http.method",     $env->{REQUEST_METHOD});
    $span->set_attribute("http.user_agent", $env->{HTTP_USER_AGENT});
    $span->set_attribute("http.host",       $env->{HTTP_HOST});         # non-standard

    # todo
    # "http.request_content_length"

    my $res = $self->app->($env);

    my $status_code = $res->[0];
    $span->set_attribute("http.status_code", $status_code);
    if ($status_code >= 400 and $status_code <= 599) {
        $span->set_status(SPAN_STATUS_ERROR);
    }
    elsif ($status_code >= 200 and $status_code <= 399) {
        $span->set_status(SPAN_STATUS_OK);
    }

    if (ref($res) && ref($res) eq 'ARRAY') {
        my $content_length = Plack::Util::content_length($res->[2]);
        $span->set_attribute("http.response_content_length", $content_length);
        $span->end();
        return $res;
    }

    return $self->response_cb(
        $res,
        sub {
            my $res            = shift;
            my $content_length = Plack::Util::content_length($res->[2]);
            $span->set_attribute("http.response_content_length", $content_length);
            $span->set_attribute("plack.callback",               "true");
            $span->end();
        }
    );
}

1;

=head1 NAME

Plack::Middleware::OpenTelemetry - Plack middleware to handle X-Forwarded-For headers

=head1 SYNOPSIS

  builder {
    enable "Plack::Middleware::OpenTelemetry",
      tracer => OpenTelemetry->tracer_provider->tracer; # default
  };

=head1 DESCRIPTION

C<Plack::Middleware::OpenTelemetry> will setup an C<OpenTelemetry>
span for the request.

=head1 PARAMETERS

=over

=item tracer

If not specified a tracer from the default tracer_provider will be used.

=back

=head1 SEE ALSO

L<Plack::Middleware>, L<OpenTelemetry::SDK>

=head1 AUTHOR

Ask Bjørn Hansen <ask@develooper.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2023 by Ask Bjørn Hansen.

This is free software; you can redistribute it and/or modify it under
the MIT software license.

=cut
