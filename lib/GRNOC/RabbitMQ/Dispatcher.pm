#--------------------------------------------------------------------
#----- GRNOC RabbitMQ Dispatcher Library
#-----
#----- Copyright(C) 2015 The Trustees of Indiana University
#--------------------------------------------------------------------
#----- 
#----- This module wraps much of the common Rabbit related to code
#----- especially for RPC server side, and creating methods
#----- reasonably easy to develop with.
#--------------------------------------------------------------------

use strict;
use warnings;

package GRNOC::RabbitMQ::Dispatcher;

use AnyEvent;
use GRNOC::Log;
use GRNOC::RabbitMQ;

=head1 NAME

GRNOC::RabbitMQ::Dispatcher - GRNOC centric RabbitMQ RPC Dispatcher

=head1 SYNOPSIS

This modules provides AMQP programmers with an abstracted JSON/AMQP base 
object.  The object handles the taks of input/param validation.

It takes care of handling the response back to the caller over Rabbit.

Here is an example of how to use this

use GRNOC::RabbitMQ::Dispatcher;
use GRNOC::RabbitMQ::Method;

sub main{

    my $dispatcher = GRNOC::RabbitMQ::Dispatcher->new(queue => "OF-FWDCTL",
                                                      topic => "OF.FWDCTL",
                                                      exchange => 'OESS',
                                                      user => 'guest',
                                                      pass => 'guest');

    my $method = GRNOC::RabbitMQ::Method->new( name => "plus",
                                               callback => \&do_plus,
                                               description => "Add numbers a and b together" );
    $method->set_schema_validator( schema => {} );

    $method->add_input_parameter( name => 'a',
                                  description => 'first addend',
                                  pattern => '^(-?[0-9]+)$' );

    $method->add_input_parameter( name => 'b',
                                  description => 'second addend',
                                  pattern => '^(-?[0-9]+)$' );

    $dispatcher->register_method( $method );

    $dispatcher->start_consuming();
}

sub do_plus{
    my ($method_obj,$params,$state) = @_;

    my $a = $params->{'a'}{'value'};
    my $b = $params->{'b'}{'value'};

    return { result => ($a+$b) };
}

main();

=cut

sub new{
    my $that  = shift;
    my $class =ref($that) || $that;
    
    my %args = (
        debug                => 0,
        topic => undef,
        host => 'localhost',
        port => 5672,
        user => undef,
        pass => undef,
        vhost => '/',
        timeout => 1,
        queue => undef,
        exchange => '',
        on_success => \&GRNOC::RabbitMQ::channel_creator,
        on_failure => \&GRNOC::RabbitMQ::on_failure_handler,
        on_read_failure => \&GRNOC::RabbitMQ::on_failure_handler,
        on_return => \&GRNOC::RabbitMQ::on_failure_handler,
        on_close => \&GRNOC::RabbitMQ::on_close_handler,
        @_,
        );
    
    my $self = \%args;
    
    #--- register builtin help method
    bless $self,$class;
    
    $self->{'logger'} = GRNOC::Log->get_logger();
    
    if(!defined($self->{'topic'})){
        $self->{'logger'}->error("No topic defined!!!");
        return;
    }
    $self->connected(0);
    $self->_connect_to_rabbit();
    
    #--- register the help method
    my $help_method = GRNOC::RabbitMQ::Method->new(
        name         => "help",
        description  => "The help method!",
        is_default   => 1,
        callback     => \&help,
        );
    
    $help_method->set_schema_validator(
        schema => { 'type' => 'object',
                    'properties' => { "method_name" => {'type' => 'string'} }}
        );
    
    $self->register_method($help_method);
    
    
    return $self;
    
}

sub _connect_to_rabbit{
    
    my $self = shift;
    
    $self->{'logger'}->debug("Connecting to RabbitMQ");
    
    my $ar = GRNOC::RabbitMQ::connect_to_rabbit(
        host => $self->{'host'},
        port => $self->{'port'},
        user => $self->{'user'},
        pass => $self->{'pass'},
        vhost => $self->{'vhost'},
        timeout => $self->{'timeout'},
        tls => 0,
        exchange => $self->{'exchange'},
        type => 'topic',
        obj => $self,
        exclusive => 0,
        queue => $self->{'queue'},
        on_success => $self->{'on_success'},
        on_failure => $self->{'on_failure'},
        on_read_failure => $self->{'on_read_failure'},
        on_return => $self->{'on_return'},
        on_close => $self->{'on_close'}
        );
    
    if(!defined($ar)){
        warn "Unable to connect to rabbit\n";
        return;
    }
    
    $self->connected(1);
    
    
    $self->{'ar'} = $ar;

    my $dispatcher = $self;
    $self->{'rabbit_mq'}->consume( queue => $self->{'rabbit_mq_queue'}->{method_frame}->{queue},
                                   on_consume => sub {
                                       my $message = shift;
                                       $dispatcher->handle_request($message);
                                   });
    
    return;
    
}

=head2 _set_channel

=cut

sub _set_channel{
    my $self = shift;
    my $channel = shift;
    $self->{'rabbit_mq'} = $channel;
}

=head2 _set_queue

=cut

sub _set_queue{
    my $self = shift;
    my $queue = shift;
    $self->{'rabbit_mq_queue'} = $queue;
}

=head2 help()
returns list of avail methods or if parameter 'method_name' provided, the details about that method
=cut
sub help{
    my $m_ref   = shift;
    my $params  = shift;

    my %results;

    my $method_name = $params->{'method_name'}{'value'};
    my $dispatcher = $m_ref->get_dispatcher();

    if (!defined $method_name) {
	return $dispatcher->get_method_list();
    }
    else {
	my $help_method = $dispatcher->get_method($method_name);
	if (defined $help_method) {
	    return $help_method->help();
	}
	else {
	    $m_ref->set_error("unknown method: $method_name\n");
	    return undef;
	}
    }
}


#----- formats results in JSON then seddts proper cache directive header and off we go
sub _return_error{
    my $self        = shift;
    my $reply_to    = shift;
    my $rabbit_mq_connection = $self->{'rabbit_mq'};

    my %error;

    $error{"error"} = 1;
    $error{'error_text'} = $self->get_error();
    $error{'results'} = undef;
    
    if(!defined($reply_to->{'routing_key'})){
	$rabbit_mq_connection->ack();
	return;

    }
    
    $rabbit_mq_connection->publish( exchange => $reply_to->{'exchange'},
				    routing_key => $reply_to->{'routing_key'},
				    header => {'correlation_id' => $reply_to->{'correlation_id'}},
				    body => JSON::XS::encode_json(\%error));
    $rabbit_mq_connection->ack();
    
}


=head2 handle_request

=cut

sub handle_request{
    my $self = shift;
    my $var = shift;

    my $state = $self->{'state'};
    my $reply_to = {};
    if(defined($var->{'header'}->{'no_reply'}) && $var->{'header'}->{'no_reply'} == 1){

	$self->{'logger'}->debug("No Reply specified");
	
    }else{
	$self->{'logger'}->debug("Has reply specified");
	$reply_to->{'exchange'} = $var->{'deliver'}->{'method_frame'}->{'exchange'};
	$reply_to->{'correlation_id'} = $var->{'header'}->{'correlation_id'},
	$reply_to->{'routing_key'} = $var->{'header'}->{'reply_to'};
    }

    my $method = $var->{'deliver'}->{'method_frame'}->{'routing_key'};



    
    if(!defined($method)){
	$method = "help";
    }
    
    #--- check for properly formed method
    if (!defined $method) {
	$self->_set_error("format error with method name");
	$self->_return_error($reply_to);
	return undef
    }

    #--- check for method being defined
    if (!defined $self->{'methods'}{$method}) {
	$self->_set_error("unknown method: $method");
	$self->_return_error($reply_to);
	return undef;
    }
    
    #--- have the method do its thing;
    $self->{'methods'}{$method}->handle_request( $self->{'rabbit_mq'},
						 $reply_to,
						 $var->{'body'}->{'payload'},
						 $self->{'default_input_validators'},
						 $state);

    return 1;
}


=head2 get_method_list()
Method to retrives the list of registered methods
=cut

sub get_method_list{
    my $self        = shift;

    my @methods =  sort keys %{$self->{'methods'}};
    return \@methods;

}


=head2 get_method($name)
returns method ref based upon specified name
=cut

sub get_method{
    my $self        = shift;
    my $name  = shift;

    return $self->{'methods'}{$name};
}



=head2 get_error()
gets the last error encountered or undef.
=cut

sub get_error{
    my $self  = shift;
    return $self->{'error'};
}


=head2 _set_error()
protected method which sets a new error and prints it to stderr
=cut

sub _set_error{
    my $self  = shift;
    my $error = shift;

    $self->{'logger'}->error($error);
    $self->{'error'} = $error;
}


=head2 register_method()
This is used to register a web service method.  Three items are needed
to register a method: a method name, a function callback and a method configuration.
The callback will accept one input argument which will be a reference to the arguments
structure for that method, with the "value" attribute added.
The callback should return a pointer to the results data structure.
=cut
sub register_method{
    my $self  = shift;
    my $method_ref  = shift;

    my $topic = $self->{'topic'};
    if(defined($method_ref->{'topic'})){
        $topic = $method_ref->{'topic'};
    }

    $method_ref->update_name( $topic . "." .  $method_ref->get_name());
    
    my $method_name = $method_ref->get_name();
    
    if (!defined $method_name) {
	$self->{'logger'}->error(ref $method_ref."->get_name() returned undef");
	return;
    }

    if (defined $self->{'methods'}{$method_name}) {
	$self->logger->error("$method_name already exists");
	return;
    }

    $self->{'methods'}{$method_name} = $method_ref;
    if ($method_ref->{'is_default'}) {
	$self->{'default_method'} = $method_name;
    }
    #--- set the Dispatcher reference
    $method_ref->set_dispatcher($self);

    my $cv = AnyEvent->condvar;

    $self->{'rabbit_mq'}->bind_queue( queue => $self->{'rabbit_mq_queue'}->{method_frame}->{queue},
				      exchange => $self->{'exchange'},
				      routing_key => $method_ref->get_name(),
				      on_success => sub {
					  $cv->send();
				      });
    
    $cv->recv;

    return 1;
}

=head2 connected

=cut

sub connected {
    my ($self, $connected) = @_;

    $self->{'connected_to_rabbit'} = $connected if(defined($connected));
    
    return $self->{'connected_to_rabbit'};
}

=head2 consuming

=cut

sub consuming{
    my ($self, $consuming) = @_;

    $self->{'is_consuming'} = $consuming if(defined($consuming));

    return $self->{'is_consuming'};
}

=head2 start_consuming

please note that start_consuming will block forever in your application

=cut

sub start_consuming{
    my $self = shift;
    $self->consuming(1);    
    $self->{'consuming_condvar'} = AnyEvent->condvar;
    $self->{'consuming_condvar'}->recv();
}

=head2 stop_consuming

=cut

sub stop_consuming{
    my $self = shift;
    $self->consuming(0);
    $self->{'consuming_condvar'}->send();
}

1;
