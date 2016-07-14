#!perl

use Carp;
use Getopt::Long qw(:config no_ignore_case);
our $cfg={};
GetOptions($cfg, qw(port|P=s logpath=s capfilepath=s start|s=s end|e=s storage|d=s poll|p=s max_edges|me=s
           max_nodes|mn=s async_write|aw|D=s select|S=s@
           ));
#$SIG{__DIE__} = sub { Carp::confess( @_ ) };
#@SIG{'INT','BREAK'} = ( sub { die } )x2;


graph_svc::start_server($cfg);

package graph_svc;
use Data::Dumper;
use strict;
use threads;
use threads::shared;
use Thread::Queue;
use common;

use XMLRPC::Lite +trace => [
#dispatch => \&log_dispatch,
#result => \&log_result,
#parameters => \&log_parameters,
#headers => \&log_headers,
#objects => \&log_objects,
#method => \&log_method,
#fault => \&log_fault,
#freeform => \&log_freeform,
#trace => \&log_trace,
debug => \&log_debug
#all => \&log_debug
] ;

use XMLRPC::Transport::HTTP;
use lib 'J:/projects/perl/kmg/gather';
use lib 'J:/projects/perl/kmg/SOAP';
use lib 'E:/work/kmg/gather';
use lib 'E:/work/kmg/SOAP/';
use query_graph_object;
use query_graph_soap;


#my $qg;

our $xmlt = <<'EOM';
<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soapenc="http://schemas.xmlsoap.org/soap/encoding/"
                   soap:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
                   xmlns:xsi="http://www.w3.org/1999/XMLSchema-instance"
                   xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
                   xmlns:xsd="http://www.w3.org/1999/XMLSchema">
<soap:Body>
<namesp1:add xmlns:namesp1="http://www.soaplite.com/Calculator">
  <c-gensym5 xsi:type="xsd:int">2</c-gensym5>
  <c-gensym7 xsi:type="xsd:int">5</c-gensym7>
</namesp1:add>
</soap:Body>
</soap:Envelope>
EOM


1;

my $server_th;
sub finish {
  print STDERR "main: finishing\n";
  #map $_->kill('__DIE__'),threads->list();
  map {
    printf STDERR "killing thread:%s,%s\n", $_, $_->tid();
    if ($_->equal($server_th)) {
      $_->kill('INT');
    }
    else {
      $_->kill('INT');
    }
    }  threads->list();
  #$wait=0;
}

sub start_server {
  #@SIG{'INT','BREAK'} = ( \&finish )x2;

  $SIG{'INT'} = \&finish ;

	my ($cfg)=@_;
	$cfg//={};

  open my $f, '>:raw', 'kkth.cmd';
  print {$f} qq{taskkill /f /fi "imagename eq perl.exe" /fi "pid eq $$"\n};
  close $f;

  my $logs=  [ map { common->newlog(file=>$_) } ("${0}.log", "-") ];

  logm("pid=$$", $logs);

  #($qg)=query_graph_object->new($cfg);


  my $db_in_q = Thread::Queue->new();
  my $db_out_q = Thread::Queue->new();

  my $db_obj =  query_graph_soap->new({ type=>'db', db_in_q=>$db_in_q, db_out_q=>$db_out_q, async_write=>$cfg->{async_write}, qg_cfg=>$cfg});
  my $soap_obj =  query_graph_soap->new({ type=>'soap',  db_in_q=>$db_in_q, db_out_q=>$db_out_q, gq_cfg=>$cfg});
  my $async_write_obj;
  if ($cfg->{async_write}) {
    $async_write_obj=  query_graph_soap->new({ type=>'async_write', db_in_q=>$db_in_q, db_out_q=>$db_out_q, gq_cfg=>$cfg});
  }
  my $polling_obj;
  if ($cfg->{poll}) {
    $polling_obj=  query_graph_soap->new({ type=>'polling', db_in_q=>$db_in_q, db_out_q=>$db_out_q, gq_cfg=>$cfg});
  }

  logm( (sprintf "passing to queue_loop: db_in_q=%s, db_out_q=%s\n", ref $db_obj->{db_in_q}, ref $db_obj->{db_out_q}),$logs);
  my $db_thread  = threads->create(\&query_graph_soap::queue_loop, $db_obj, $cfg);
  logm("created db thread",$logs);
  #print STDERR Dumper($gs->{qg}{cfg});



  #printf STDERR "created soap object: qg is_shared: %d\n", is_shared($gs->{qg});

  #my $gs = query_graph_soap->new({ db_async_write=>$cfg->{db_async_write}//0} );
  #printf STDERR "created soap object: qg is_shared: %d\n", is_shared($gs->{qg});


  if (1==1) {
    $server_th = threads->create(\&server, $soap_obj, $cfg);
  }
  logm("created server thread",$logs);
  #print STDERR Dumper($gs->{qg}{cfg});

  my $async_write_th;
  if ($async_write_obj) {
    $async_write_th = threads->create(\&query_graph_soap::async_write, $async_write_obj, $cfg);
    logm("created server thread",$logs);
  }

  my $polling_th;
  if ($polling_obj) {
    $polling_th = threads->create(\&query_graph_soap::polling, $polling_obj, $cfg);
    logm("created polling thread",$logs);
  }

  #print STDERR Dumper($gs->{qg}{cfg});

  while (threads->list()) {
   my @joinable = threads->list(threads::joinable);
   if (@joinable) {
    for(@joinable) {
      printf STDERR "joining: %s\n", $_->tid();
      $_->join for @joinable;
    }
   } else {
      #print STDERR "sleeping:\n";
      sleep(1);
   }
  }
}


sub server {
	my ($soap_obj, $cfg)=@_;
  $SIG{__DIE__} = sub { Carp::confess( @_ ) };
  $SIG{'INT'} = sub { print STDERR "soap_server:@_\n"; Carp::confess();};
#  $SIG{'CHLD'} = sub { print STDERR "soap_server:@_\n"; print STDERR Devel::StackTrace->new(); threads->exit();};
  printf STDERR "server: my SIG{INT} is:%s\n", $SIG{INT};
  #$SIG{'KILL'} = sub { print STDERR "soap_server:@_\n"; threads->exit()};
  #@SIG{'INT','BREAK'} = ( sub { print STDERR "singal:@_";die } )x2;
	#$SIG{'KILL'} = sub { threads->exit(); };

	$cfg//={};
  print STDERR (sprintf "passing to server: soap_obj=%s, db_in_q=%s, db_out_q=%s\n", Scalar::Util::refaddr($soap_obj), ref $soap_obj->{db_in_q}, ref $soap_obj->{db_out_q});
  #my $dispatchers = {
  #  'urn:spawned'=>$gs,
  #  'urn:handler'=>$gs
  #};


  my $PORT=$cfg->{port}//12345;

  #my $srv = XMLRPC::Server->dispatch_to($gs);

  my $daemon = XMLRPC::Transport::HTTP::Daemon
            ->new(LocalPort => $PORT)
            ->dispatch_to($soap_obj)
            ->handle( );

  return $daemon;

}

sub log_it {
  my $method = shift;
  #open LOGFILE, ">>server.log";
  #print LOGFILE  "$method: $_[0]\n";
  my $t = $_[0]=~s{(?<=>)([^<]{2000})([^<]*)}{$1...}sgr;
  #close LOGFILE;
  common::log(">>> $method: $t", "${0}_trace.log");
}

sub log_dispatch { &log_it('dispatch',@_) };
sub log_result { &log_it('result',@_) };
sub log_parameters { &log_it('parameters',@_) };
sub log_headers { &log_it('headers',@_) };
sub log_objects { &log_it('objects',@_) };
sub log_method { &log_it('method',@_) };
sub log_fault { &log_it('fault',@_) };
sub log_freeform { &log_it('freeform',@_) };
sub log_trace { &log_it('trace',@_) };
sub log_debug { &log_it('DEBUG',@_) };

package Calculator;
  sub new { bless {} => ref($_[0]) || $_[0] }
  sub add { $_[1] + $_[2] }
  sub schema { $SOAP::Constants::DEFAULT_XML_SCHEMA }
1;


=pod
package query_graph_soap;
suse strict;
our $init="init";
our $new;
our $result;

1;

sub new
{
	my ($result)=@_;
  $new = "new";
  $query_graph_soap::result = $result;
	my $self=bless {result=>$result} ;
  return $self;
}

sub handler {
  my ($self, $args) = @_;
  print STDERR map { qq{$_: $args->{$_}} } sort keys %$args;
  #$result="handler";
  return { sorted=>$result};
}

=cut