package query_graph_soap;
use strict;
use threads;
use threads::shared;
use Thread::Queue;
use SOAP::Lite;
use lib 'E:\work\kmg\gather';
use lib 'J:\projects\perl\kmg\gather';
use query_graph_object;
use Data::Dumper;
use JSON::XS;
use Scalar::Util;
use Carp;
use Devel::StackTrace;
use Encode;
#use Clone qw(clone);
use common;

$SIG{__DIE__} = sub { Carp::confess( @_ ) };
#@SIG{'INT','BREAK'} = ( sub { die } )x2;

#$SIG{__DIE__} = sub { printf STDERR "%s: SIG{__DIE__}:\n", __PACKAGE__; Carp::confess( @_ ) };

our $json=JSON::XS->new->canonical;

#use vars qw(@ISA);
#@ISA = qw(Exporter SOAP::Server::Parameters);

our $init="init";
#our $new;
#our $result;

#$log->dlog("starting");
my $db_lock :shared =1;

our $diecount=0;
1;

=pod
sub mylog {
  my ($msg,$file)=@_;
  if ($file eq 'STDERR') {
    print STDERR sprintf ("~%s: %s", threads->tid(), $msg);
  }
  $log->dlog(sprintf ("~%s: %s", threads->tid(), $msg),2);
}
=cut


sub dumper {
    my $t = Data::Dumper->new(\@_)->Terse(1)->Sortkeys(1)->Maxdepth(2)->Dump();
    if (length($t) > 1500) {
      $t=substr($t,0,1497).'...';
    }
    $t
}

sub new {

	my ($self, $cfg)=@_;
  my $qg_cfg = $cfg->{qg_cfg};
  die "no instance" if $self ne __PACKAGE__;

  if ($cfg->{type} eq 'db') { #db thread
    my $qg = query_graph_object->new($qg_cfg);

    #my $qg = shared_clone($qg);
    #printf STDERR "%s, is_shared=%d, %s, %s\n", ref $qg, is_shared($qg), ref $qg->{links}, join ';', keys %$qg;
    #printf STDERR "before share: requests=%d, edges=%d\n", $qg->{requests}, @{$qg->{links}};
    #share($qg);
    #printf STDERR "after share: requests=%d, edges=%d\n", $qg->{requests}, @{$qg->{links}};
    my $log = common->newlog(file=>"${0}_db.log");
    logm((__PACKAGE__."->new: " . join '',  map { qq{$_: $cfg->{$_}\n} } sort keys %$cfg),[$log]);
    logm(("query_graph_object->new: " . join '',  map { qq{$_: $qg_cfg->{$_}\n} } sort keys %$qg_cfg),[$log]);
    logm("".Dumper($qg_cfg->{cfg}),[$log]);
    $self=bless { qg=>$qg, cfg=>$cfg, db_in_q=>$cfg->{db_in_q}, db_out_q=>$cfg->{db_out_q}, log=>$log} ;
    return $self;
  }
  elsif ($cfg->{type} eq 'soap') {
    my $log = common->newlog(file=>"${0}_soap.log");
    $self=bless { cfg=>$cfg, db_in_q=>$cfg->{db_in_q}, db_out_q=>$cfg->{db_out_q}, token=>0, log=>$log} ;
    return $self;
  }
  elsif ($cfg->{type} eq 'polling' ) {
    my $log = common->newlog(file=>"${0}_poll.log");
    $self=bless { cfg=>$cfg, db_in_q=>$cfg->{db_in_q}, db_out_q=>$cfg->{db_out_q}, token=>0, log=>$log} ;
    return $self;
  }
  elsif ($cfg->{type} eq 'async_write' ) {
    my $log = common->newlog(file=>"${0}_async_write.log");
    $self=bless { cfg=>$cfg, db_in_q=>$cfg->{db_in_q}, db_out_q=>$cfg->{db_out_q}, token=>0, log=>$log} ;
    return $self;
  }
  else {
    die "wrong thread type specified: $cfg->{type}";
  }
}

sub log {
  my($self,$msg)=@_;
  common::logm($msg, [$self->{log}]);
}

sub queue_loop { # in db thread
  my ($self,$args)=@_;
  #$SIG{__DIE__} = sub { print STDERR "queue_loop:DIE $diecount\n"; $diecount++; };
  $SIG{'INT'} = sub { print STDERR "queue_loop:@_\n"; Carp::confess();};
  $SIG{'KILL'} = sub { print STDERR "queue_loop:@_\n"; threads->exit()};
  #map { $SIG{$_} = sub { print STDERR "signal:@_";die } } qw(INT BREAK);
  #$SIG{'KILL'} = sub { threads->exit(); };



  print STDERR (sprintf "got from caller: db_in_q=%s[%s], db_out_q=%s[%s]\n"
                , ref$self->{db_in_q}, Scalar::Util::refaddr($self->{db_in_q})
                , ref$self->{db_out_q}, Scalar::Util::refaddr($self->{db_out_q}));


  my ($db_in_q, $db_out_q) = @$self{qw(db_in_q db_out_q)};

  my $logs=  [ map { common->newlog(file=>$_) } ("${0}_queue.log", "-") ];

  my @method_names = qw(rescan write_if_changed spawned clicked navigated completed_loading switch_session query_storage
    update_node_info save_new_elements get_node_info get_graph_data_with_stats);
  my $methods ={};
  for my $method (@method_names) {
    eval "\$methods->{'$method'} = \\&_$method";
    if ($@) {
      die $@;
    }
  }

  #logm(sprintf ("still there: db_in_q=%s, db_out_q=%s\n", ref$self->{db_in_q}, ref$self->{db_out_q}), $logs) ;
  #logm(sprintf ("running: %s\n", $methods->{get_node_info}), $logs);
  #my $r= $methods->{get_node_info}($self);
  #logm(sprintf ("returned: %s\n", $r), $logs);


  logm(sprintf ("%s\n", Dumper($methods)), $logs);

  logm(sprintf ("queue_loop: qg=%s, is_shared=%d, args=%s\n", ref $self, is_shared($self), ref $args),$logs);

  while (1) {
    my $_req  = $db_in_q->dequeue_nb();
    if (!defined $_req ) {
      sleep .2; next
    }
    if ($_req eq 'stop') {
      logm("exiting");
      last;
    }
    my $req = common::clone($_req);
    my $method= $methods->{$req->{method}};
    my $token = $req->{token};
    my $args=$req->{args};
    if (!defined $method || !defined $token) {
      logm((sprintf "wrong call: method=%s, token=%s\n", $req->{method}, $req->{token}),$logs);
      $db_out_q->enqueue({method=>$req->{method}, token=>$token, result=>{ result=>'failure', message=>'wrong call'}});
    }
    else {
      my $result = $method->($self,$req->{args});
      logm((sprintf "method: %s, token=%s, req.is_shared=%d, args=%s\n"
                 , $req->{method}, $req->{token}, is_shared($req), Dumper($args)),$logs);

      $db_out_q->enqueue({method=>$req->{method}, token=>$token, result=>$result });
      logm((sprintf "enqueued: method: %s, token=%s, req.is_shared=%d, result=%s\n"
                 , $req->{method}, $req->{token}, is_shared($req), dumper($result)),$logs);


    }
  }
}


=pod
sub _rescan {
  my ($self)=@_;
  die "no instance" if ref $self ne __PACKAGE__;
  my $changes ;
  if (($changes=$self->{qg}->get_new_requests())) {
		$self->{qg}->write_db();
	}
  #my $sorted = $g->get_sorted();
  common::log("changes=$changes");
}
=cut

sub stop {
  my ($self)=@_;
  lock($db_lock);
  $db_lock=0;
}

sub polling {
  my ($self,$args)=@_;
  #$SIG{__DIE__} = sub { Carp::confess( @_ ) };
  #map { $SIG{$_} = sub { print STDERR "signal:@_";die } } qw(INT BREAK);
  #$SIG{'KILL'} = sub { threads->exit(); };

  $SIG{__DIE__} = sub { print STDERR "signal:@_"; Carp::confess( @_ ); };
  $SIG{INT} = sub { print STDERR "signal:@_"; Carp::confess( @_ ) ; threads->exit();};

  $self->log(sprintf "polling: self=%s, is_shared=%d, args=%s\n", ref $self, is_shared($self), ref $args);
  #die "no instance" if ref $self ne __PACKAGE__;


  #my ($args)=@_;
  my $interval = $args->{interval};
  if ($interval < 5 ) {
    warn "the interval is too small: $interval";
    $interval = 10;
  }

  my $total_changes;

  for(my $token=0;;$token++)  {
#      my $total_requests = $qg->{requests};

    $self->log(sprintf  "polling enqueue: args=%s\n", Dumper($args));
    $self->{db_in_q}->enqueue({method=>'get_new_requests', token=>$token});
    my $_result;
    while (1) {
      $_result= $self->{db_out_q}->dequeue_nb();
      last if (defined $_result);
      sleep .1; next;
    }
    my $result = common::clone($_result);
    if (!$result) {
      $self->log(sprintf  "polling: new: none, total changes=%s: \n", $total_changes);
    }
    else {
      $self->log(sprintf  "polling: new: %s, total changes=%s\n", $result, $total_changes);
    }
    sleep $interval
  }
}

sub async_write {
  my ($self,$args)=@_;
  #$SIG{__DIE__} = sub { Carp::confess( @_ ) };
  #map { $SIG{$_} = sub { print STDERR "signal:@_"; die } } qw(INT BREAK);
  #$SIG{'KILL'} = sub { threads->exit(); };
  $SIG{__DIE__} = sub { print STDERR "signal:@_"; Carp::confess( @_ );  };
  $SIG{INT} = sub { print STDERR "signal:@_"; Carp::confess( @_ ) ; threads->exit(); };
  my $logs=  [ $self->{log}, common->newlog(file=>"-")];
  $self->log(sprintf "async_write: self=%s, is_shared=%d, args=%s\n", ref $self, is_shared($self), ref $args);
  #die "no instance" if ref $self ne __PACKAGE__;

  #my ($args)=@_;
  my $interval = $args->{async_write};
  if ($interval < 5 ) {
    warn "the interval is too small: $interval";
    $interval = 10;
  }
  printf STDERR "async_write: using interval %s\n", $interval;

  my $total_changes=0;

  for(my $token=0;;$token++)  {
#      my $total_requests = $qg->{requests};

    #$self->log(sprintf  "async_write enqueue: args=%s\n", Dumper($args));
    $self->{db_in_q}->enqueue({method=>'write_if_changed', token=>$token});
    my $_result;
    while (1) {
      $_result= $self->{db_out_q}->dequeue_nb();
      last if (defined $_result);
      sleep .1; next;
    }
    my $result = common::clone($_result);

    if (!$result->{result}) {
      common::logm((sprintf  "async_write: new: none, total changes=%s: \n", $result->{result}, $total_changes),$logs);
    }
    else {
      $total_changes+=$result->{result};
      common::logm((sprintf  "async_write: new: %s, total changes=%s\n", $result->{result}, $total_changes),$logs);
    }
    sleep $interval
  }
}

=pod
sub rescan {
  my ($self, $args) = @_;
  die "no instance" if ref $self ne __PACKAGE__;
  #$DB::single=1;
  common::log("*** call: rescan");
  common::log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
	my $result = { };
	eval {
    $self->_rescan();
	  $result = { result=>"success"};
	};
	if ($@) {
		$result = { result=>"failure", error=>$@ };
	}
	return $result;
}

=cut

####### db API
sub _rescan {
  my ($self)=@_;
  my ($qg)=$self->{qg};
  my $changes ;
  #printf STDERR "%s.%s:%s:%s > _rescan: calling get_new_requests: %s\n", ((caller(1))[0,3,1,2]), ref $qg;

  if (($changes=$qg->get_new_requests())) {
		$qg->write_db();
	}
  my $str= sprintf "new requests: %s changes\n", $changes;
  $self->log($str);
  common::logm($str, [ common->newlog(file=>"-") ]) if $changes > 0;

  #printf STDERR "%s changes\n", $changes if $changes > 0;
}

sub _stats {
  my ($self, $args) = @_;
  die "no instance" if ref $self ne __PACKAGE__;
  #$DB::single=1;

  my $qg = $self->{qg};

  $self->log("*** call: stats");
  $self->log("".Dumper($qg->{cfg}));
	$self->log(join '',  map { qq{$_: $args->{$_}\n} } sort keys %$args);
	my $result = { };
  my $rc;
  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }

    eval {
=pod
      if ($args->{update}==1) {
        $self->log("refreshing the database");
        _rescan($self->{qg});
      }
=cut
      $result = { result=>"success", stats=>ref $self->{qg} ne '' ? $self->{qg}->get_query_stats($args) : ''};
    };
    if ($@) {
      $result = { result=>"failure", message=>$@ };
    }
  };

  #print STDERR "result: ", map { qq{$_: $result->{$_}\n} } sort keys %$result;
  $self->log("result: $result->{result}, message: $result->{message}");
	return $result;
}

sub _write_if_changed  {
  my ($self, $args) = @_;
  return $self->{qg}->write_if_changed();
}

sub _spawned {
  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: spawned");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
  my $result;
  my $rc;
  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval {
      if ($args->{type} !~ /^(query|new_tab|jump)$/) {
        return { result=> "wrong call arguments"};
      }
      $rc  =$j->add_browser_data($args);
      if ($rc && !$self->{cfg}{async_write}) {
        $j->write_db();
      }
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif ($rc ) {
    $result = {result=>"success", message=>$rc};
  }
  else {
    $result = {result=>"failure", message=>$rc};
  }
  $self->log("result: $result->{result}, message: $result->{message}");
  return $result;
}

sub _clicked {
  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: clicked");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
  my $result;
  my $rc;
  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval {
      if ($args->{type} !~ /^(query|new_tab|jump|click)$/) {
        return { result=> "wrong call arguments"};
      }
      $rc  =$j->add_browser_data($args);
      if ($rc) {
       ; #  $j->write_db();
      }
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif ($rc ) {
    $result = {result=>"success"};
  }
  else {
    $result = {result=>"failure", message=>$rc};
  }
  $self->log("add_browser_data: result=$result->{result}, message=$result->{message}");
  return $result;
}

sub _navigated {
  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: navigated");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
  my $result;
  my $rc;
  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    $rc = eval {
      if ($args->{type} !~ /^(query|new_tab|(nav|tab)_(typed|form_submit|jump|link))$/) {
        #$self->log(sprintf "wrong call arguments: '%s'", $args->{type});
        return "wrong call arguments: $args->{type}";
      }
      #$self->log(sprintf "calling add_browser_data: '%s'", dumper($args));
      my $rc  =$j->add_browser_data($args);
      return $rc;
      #$self->log(sprintf "add_browser_data returned: '%s'", $rc);
      #if ($rc) {
      # ; #  $j->write_db();
      #}
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif ($rc==1) {
    $result = {result=>"success"};
  }
  else {
    $result = {result=>"failure", message=>$rc};
  }
  $self->log("add_browser_data: result=$result->{result}, message=$result->{message}");
  return $result;
}

sub _completed_loading {
  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: _completed_loading");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
  my $result;
  my $rc;
  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    $rc = eval {
      #if ($args->{type} !~ /^(query|new_tab|nav_typed|nav_form_submit|jump|tab_link|nav_link)$/) {
      #  #$self->log(sprintf "wrong call arguments: '%s'", $args->{type});
      #  return "wrong call arguments: $args->{type}";
      #}
      #$self->log(sprintf "calling add_browser_data: '%s'", dumper($args));
      my $rc  =$j->update_node_info($args);
      return $rc;
      #$self->log(sprintf "add_browser_data returned: '%s'", $rc);
      #if ($rc) {
      # ; #  $j->write_db();
      #}
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif (ref $rc ne 'HASH') {
    $result = {result=>"failure", message=>$rc};
  }
  else {
    $result = {result=>"success"};
  }
  $self->log("add_browser_data: result=$result->{result}, message=$result->{message}");
  return $result;
}


sub _query_storage  {

  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: query_storage: async_write=$self->{cfg}{async_write}");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);

  my $result;

  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval  {
      $result= $j->query_storage($args);
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif (ref $result ne 'HASH') {
    $result = { result=>"failure", message=>"no expected data returned" };
  }
  else {
    $result->{result} = "success";
  }
	$self->log("result: $result->{result}, message: $result->{message}");
  return $result;
}

sub _update_node_info {

  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: update_node_info: async_write=$self->{cfg}{async_write}");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);

  my $result;

  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval  {
      for (keys %$args) {
        $args->{$_}=decode('utf8', $args->{$_});
      }
      $result= $j->update_node_info($args);
      if ($result && !$self->{cfg}{async_write}) {
        $j->write_db();
      }
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif (ref $result ne 'HASH') {
    $result = { result=>"failure", message=>"no expected data returned" };
  }
  else {
    $result->{result} = "success";
  }
  #$self->log("update_node_info: $result->{result}");
	$self->log("result: $result->{result}, message: $result->{message}");
  return $result;
}

sub _switch_session {

  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log(sprintf "*** call: switch_session: %s", dumper($args));
  #$self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);

  my $result;

  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval  {
      $result= $j->switch_session($args);
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif ($result != 1) {
    $result = { result=>"failure", message=>"switch_session: operation failed" };
  }
  else {
    $result= {result => "success" };
  }
  #$self->log("switch_session: $result");
	$self->log("result: $result->{result}, message: $result->{message}");
  return $result;
}

sub _save_new_elements {
  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: save_new_elements: async_write=$self->{cfg}{async_write}");
  print STDERR ("*** call: save_new_elements: async_write=$self->{cfg}{async_write}\n");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
  if ($args->{elements} ne '' && ref $args->{elements} eq '') {
    $args->{elements} = $json->decode(decode('utf8', $args->{elements}));
    $self->log(sprintf "*** call: save_new_elements: decoded elements:\n%s\n", Dumper($args->{elements}));
  }

  my $result;

  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval  {
      $result= $j->save_new_elements($args);
      if ($result && !$self->{cfg}{async_write} ) {
        $self->log("*** call: save_new_elements: writing to the db...");
        $j->write_db();
      }
      else {
        $self->log("*** call: save_new_elements: not writing to the db... changes=$j->{changed}");
      }
    };
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  else {
		$result = { result=>"success" };
  }
  #$self->log("save_new_elements: $result->{result}");
	$self->log("result: $result->{result}, message: $result->{message}");
  return $result;
}




sub _get_node_info {
  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("*** call: get_node_info");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
  my $result;
#  my $ex;
  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval  {
      $result= $j->get_node_info($args);
    };
 #   $ex = @_;
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif (ref $result ne 'HASH') {
    $result = { result=>"failure", message=>"no expected data returned" };
  }
  else {
    $result->{result} = "success";
  }
  #$self->log("get_node_info: $result->{result}");
	$self->log("result: $result->{result}, message: $result->{message}");
  return $result;
}



sub _get_graph_data_with_stats  {
  #$DB::single=1;
  my ($self, $args) = @_;
  $self->log("enter");
  $self->log(join '',map { qq{$_: $args->{$_}\n} } sort keys %$args);
  map { $args->{$_}=~s{[\r\n]+}{}g} keys %$args;
  if ($args->{filters} ne '' && ref $args->{filters} eq '') {
    $args->{filters} = $json->decode(decode('utf8', $args->{filters}));
    $self->log(sprintf "decoded filter:\n%s\n", Dumper($args->{filters}));
  }

  my $result={};
  my $graph_result;
#  my $ex;
  do {
    lock $db_lock;
    if ($db_lock==0) {
      return ($result = {result=>"failure", message=>"server is stopping"});
    }
    my $j = $self->{qg};
    eval  {
      if ($args->{update}==1) {
        $self->log("refreshing the database");
        _rescan($self);
      }
      $graph_result= $j->get_graph_data_with_stats($args);
    };
 #   $ex = @_;
  };
  if ($@) {
		$result = { result=>"failure", message=>$@ };
	}
  elsif (ref $result ne 'HASH') {
    $result = { result=>"failure", message=>"no expected data returned" };
  }
  else {
    $result->{result} = "success";
    $result->{json} = encode('utf8', $json->pretty->encode ($graph_result));
  }
  #$self->log("$result->{result}");
	$self->log("result: $result->{result}, message: $result->{message}");
  return $result;
}


###### gateway
sub _dispatch {
  my ($self, $args)=@_;
  my $token=0;#=$self->{token}++;
  #printf STDERR "_dispatch: self=%s[%s], args=%s, db_in_q=%s[%s], db_out_q=%s[%s], keys=%s\n"
  #, ref$self, Scalar::Util::refaddr($self), Dumper($args)
  #, ref$self->{db_in_q}, Scalar::Util::refaddr($self->{db_in_q}), ref$self->{db_out_q}, Scalar::Util::refaddr($self->{db_out_q}), join ',', keys %$self
  #;
  printf STDERR "_dispatch enqueue: args=%s\n", Dumper($args);
  #print STDERR Devel::StackTrace->new();
  #printf STDERR "_dispatch: my SIG{INT} is:%s\n", $SIG{INT};

  #$Dumper::Data::Terse=1;
  $self->{db_in_q}->enqueue({method=>$args->{method}, token=>$token, args=>$args});
  my $_result;
  while (1) {
      $_result= $self->{db_out_q}->dequeue_nb();
      last if (defined $_result);
      sleep .1; next;
    }
  #printf STDERR "_dispatch dequeue: _result=%s\n", Dumper($_result);
  my $result = common::clone($_result);
  printf STDERR "_dispatch dequeue: result keys=%s\n", join ',', sort keys %$result; #, Dumper($result);
  return $result->{result};
}

sub stats { &_dispatch };
sub spawned { &_dispatch };
sub clicked { &_dispatch };
sub navigated { &_dispatch };
sub completed_loading { &_dispatch };
sub update_node_info { &_dispatch };
sub query_storage { &_dispatch };
sub switch_session { &_dispatch };
sub save_new_elements { &_dispatch };
sub get_node_info { &_dispatch };
sub get_graph_data_with_stats { &_dispatch };
sub get_url_graph { &_dispatch };
