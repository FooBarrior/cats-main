package CATS::RunDetails;

use strict;
use warnings;

use Algorithm::Diff;
use CATS::Web qw(param encoding_param url_param headers upload_source content_type);
use CATS::DB;
use CATS::Utils qw(state_to_display url_function encodings source_encodings);
use CATS::Misc qw($is_jury $is_root $sid $t $uid init_template msg res_str url_f problem_status_names);
use CATS::Data qw(is_jury_in_contest enforce_request_state);
use CATS::IP;
use CATS::DevEnv;
use CATS::RankTable;
use CATS::Problem::Text qw(ensure_problem_hash);

sub get_judges {
    my ($si) = @_;
    $t->param('judges') or $t->param(judges => $dbh->selectall_arrayref(q~
        SELECT id, nick, lock_counter FROM judges ORDER BY nick~, { Slice => {} }));
    $si->{judges} = [ {}, map {
        value => $_->{id},
        text => $_->{nick} . ($_->{lock_counter} ? '' : ' *'),
        selected => ($_->{id} == ($si->{judge_id} || 0) ? $si->{judge_name} = $_->{nick} : 0),
    }, @{$t->param('judges')} ];
}

sub source_links {
    my ($si) = @_;
    my ($current_link) = url_param('f') || '';

    $si->{href_contest} =
        url_function('problems', cid => $si->{contest_id}, sid => $sid);
    $si->{href_problem} =
        url_function('problem_text', cpid => $si->{cp_id}, cid => $si->{contest_id}, sid => $sid);
    for (qw/run_details view_source run_log download_source/) {
        $si->{"href_$_"} = url_f($_, rid => $si->{req_id});
        $si->{"href_class_$_"} = $_ eq $current_link ? 'current_link' : '';
    }
    $t->param(is_jury => $si->{is_jury});
    get_judges($si) if $si->{is_jury};
    my $se = param('src_enc') || param('comment_enc') || 'WINDOWS-1251';
    $t->param(source_encodings => source_encodings($se));
}

sub get_run_info {
    my ($contest, $req) = @_;
    my $points = $contest->{points};

    my %run_details;
    my $rd_fields = join ', ', (
         qw(test_rank result),
         ($contest->{show_test_resources} ? qw(time_used memory_used disk_used) : ()),
         ($contest->{show_checker_comment} || $req->{partial_checker} ? qw(checker_comment) : ()),
    );

    my $c = $dbh->prepare(qq~
        SELECT $rd_fields FROM req_details WHERE req_id = ? ORDER BY test_rank~);
    $c->execute($req->{req_id});
    my $last_test = 0;
    my $total_points = 0;
    my %testset = CATS::Testset::get_testset($req->{req_id});
    $contest->{show_points} ||= 0 < grep $_, values %testset;
    my %used_testsets;

    my $comment_enc = encoding_param('comment_enc');
    while (my $row = $c->fetchrow_hashref()) {
        $_ and $_ = sprintf('%.3g', $_) for $row->{time_used};
        if ($contest->{show_checker_comment}) {
            my $d = $row->{checker_comment} || '';
            # Comment may be non-well-formed utf8
            $row->{checker_comment} = Encode::decode($comment_enc, $d, Encode::FB_QUIET);
            $row->{checker_comment} .= '...' if $d ne '';
        }

        my $prev_test = $last_test;
        $last_test = $row->{test_rank};
        my $accepted = $row->{result} == $cats::st_accepted ? 1 : 0;
        my $p = $accepted ? $points->[$row->{test_rank} - 1] || 0 : 0;
        if (my $ts = $testset{$last_test}) {
            $used_testsets{$ts->{name}} = $ts;
            push @{$ts->{list} ||= []}, $last_test;
            $ts->{accepted_count} += $accepted;
            if ($ts->{points}) {
                $total_points += $ts->{earned_points} = $ts->{points}
                    if $ts->{accepted_count} == $ts->{test_count};
            }
            else {
                $total_points += $p;
                $ts->{earned_points} += $p;
            }
            if ($ts->{hide_details} && $contest->{hide_testset_details}) {
                $row->{result} = $cats::st_ignore_submit;
            }
            if ($ts->{points} || $ts->{hide_details} && $contest->{hide_testset_details}) {
                $p = '';
            }
            $p .= " => $ts->{name}";
        }
        elsif ($accepted && $req->{partial_checker}) {
            $total_points += $p = CATS::RankTable::get_partial_points($row, $p);
        }
        else {
            $total_points += $p;
        }
        $run_details{$last_test} = {
            state_to_display($row->{result}), %$row, points => $p,
        };
        # When tests are run in random order, and the user looks at the run details
        # while the testing is in progress, he may be able to see 'OK' result
        # for the test ranked above the (unknown at the moment) first failing test.
        # Prevent this by stopping output at the first failed OR not-run-yet test.
        last if
            !$contest->{show_all_tests} &&
            (!$accepted || $prev_test != $last_test - 1);
    }
    # Output 'not processed' for tests we do not plan to run, but must still display.
    if ($contest->{show_all_tests} && !$contest->{run_all_tests}) {
        $last_test = @$points;
    }
    if ($contest->{hide_testset_details}) {
        for (values %used_testsets) {
            $_->{accepted_count} = '?'
                if $_->{hide_details} && $_->{accepted_count} != $_->{test_count};
        }
    }

    my $run_row = sub {
        my ($rank) = @_;
        return $run_details{$rank} if exists $run_details{$rank};
        return () unless $contest->{show_all_tests};
        my %r = ( test_rank => $rank );
        $r{exists $testset{$rank} ? 'not_processed' : 'not_in_testset'} = 1;
        return \%r;
    };

    my $visualizers = $dbh->selectall_arrayref(q~
        SELECT PS.id, PS.name
        FROM problem_sources PS
        INNER JOIN problems P ON PS.problem_id = P.id
        INNER JOIN reqs R ON R.problem_id = P.id
        WHERE R.id = ? AND PS.stype = ?~, { Slice => {} },
        $req->{req_id}, $cats::visualizer);

    my $add_testdata = sub {
        my ($row) = @_ or return ();
        $contest->{show_test_data} or return $row;
        my $t = $contest->{tests}->[$row->{test_rank} - 1] or return $row;
        $row->{test_data} =
            defined $t->{input} ? $t->{input} :
            $t->{gen_group} ? "$t->{gen_name} GROUP" :
            $t->{gen_name} ? "$t->{gen_name} $t->{param}" : '';
        $row->{test_data_cut} = length($t->{input} || '') > $cats::infile_cut;
        $row->{visualize_test_hrefs} =
            defined $t->{input} ? [ map +{
                href => url_f('visualize_test', rid => $req->{req_id}, test_rank => $row->{test_rank}, vid => $_->{id}),
                name => $_->{name}
            }, @$visualizers ] : [];
        $row;
    };

    return {
        %$contest,
        total_points => $total_points,
        run_details => [ map $add_testdata->($run_row->($_)), 1..$last_test ],
        testsets => [ sort { $a->{list}[0] <=> $b->{list}[0] } values %used_testsets ],
        has_visualizer => @$visualizers > 0,
    };
}

sub get_contest_info {
    my ($si, $jury_view) = @_;

    my $contest = $dbh->selectrow_hashref(qq~
        SELECT
            id, run_all_tests, show_all_tests, show_test_resources, show_checker_comment, show_test_data,
            CAST(CURRENT_TIMESTAMP - defreeze_date AS DOUBLE PRECISION) AS time_since_defreeze
            FROM contests WHERE id = ?~, { Slice => {} },
        $si->{contest_id});

    $contest->{$_} ||= $jury_view
        for qw(show_all_tests show_test_resources show_checker_comment show_test_data);
    $contest->{hide_testset_details} = !$jury_view && $contest->{time_since_defreeze} < 0;

    my $fields = join ', ',
        ($contest->{show_all_tests} ? 't.points' : ()),
        ($contest->{show_test_data} ? qq~
            (SELECT ps.fname FROM problem_sources ps WHERE ps.id = t.generator_id) AS gen_name,
            t.param, SUBSTRING(t.in_file FROM 1 FOR $cats::infile_cut + 1) AS input, t.gen_group~ : ());
    my $tests = $contest->{tests} = $fields ?
        $dbh->selectall_arrayref(qq~
            SELECT $fields FROM tests t WHERE t.problem_id = ? ORDER BY t.rank~, { Slice => {} },
            $si->{problem_id}) : [];
    my $p = $contest->{points} = $contest->{show_all_tests} ? [ map $_->{points}, @$tests ] : [];
    $contest->{show_points} = 0 != grep defined $_ && $_ > 0, @$p;
    $contest;
}

sub get_log_dump {
    my ($rid, $compile_error) = @_;
    my ($dump) = $dbh->selectrow_array(qq~
        SELECT dump FROM log_dumps WHERE req_id = ?~, undef,
        $rid) or return ();
    $dump = Encode::decode('CP1251', $dump);
    $dump =~ s/(?:.|\n)+spawner\\sp\s((?:.|\n)+)compilation error\n/$1/m
        if $compile_error;
    return (judge_log_dump => $dump);
}

sub get_nearby_attempt {
    my ($si, $prevnext, $cmp, $ord, $diff) = @_;
    # TODO: Сheck neighbour's contest to ensure correct access privileges.
    my $na = $dbh->selectrow_hashref(qq~
        SELECT id, submit_time FROM reqs
        WHERE account_id = ? AND problem_id = ? AND id $cmp ?
        ORDER BY id $ord ROWS 1~, { Slice => {} },
        $si->{account_id}, $si->{problem_id}, $si->{req_id}
    ) or return;
    for ($na->{submit_time}) {
        s/\s*$//;
        # If the date is the same with the current run, display only time.
        my ($n_date, $n_time) = /^(\d+\.\d+\.\d+\s+)(.*)$/;
        $si->{"${prevnext}_attempt_time"} = $si->{submit_time} =~ /^$n_date/ ? $n_time : $_;
    }
    my $f = url_param('f') || 'run_log';
    my @p;
    if ($f eq 'diff_runs') {
        for (1..2) {
            my $r = url_param("r$_") || 0;
            push @p, "r$_" => ($r == $si->{req_id} ? $na->{id} : $r);
        }
    }
    else {
        @p = (rid => $na->{id});
    }
    $si->{"href_${prevnext}_attempt"} = url_f($f, @p);
    $si->{href_diff_runs} = url_f('diff_runs', r1 => $na->{id}, r2 => $si->{req_id}) if $diff && $uid;
}

# Load information about one or several runs.
# Parameters: request_id, may be either scalar or array ref.
sub get_sources_info {
    my %p = @_;
    my $rid = $p{request_id} or return;

    my @req_ids = ref $rid eq 'ARRAY' ? @$rid : ($rid);
    @req_ids = map +$_, grep $_ && /^\d+$/, @req_ids or return;

    my $src = $p{get_source} ? ' S.src, DE.syntax,' : '';
    my $req_id_list = join ', ', @req_ids;
    my $pc_sql = $p{partial_checker} ? CATS::RankTable::partial_checker_sql() . ',' : '';
    # Source code can be in arbitary or broken encoding, we need to decode it explicitly.
    $dbh->{ib_enable_utf8} = 0;
    my $result = $dbh->selectall_arrayref(qq~
        SELECT
            S.req_id,$src S.fname AS file_name, S.de_id,
            R.account_id, R.contest_id, R.problem_id, R.judge_id,
            R.state, R.failed_test, R.points,
            R.submit_time,
            R.test_time,
            R.result_time,
            DE.description AS de_name,
            A.team_name, A.last_ip,
            P.title AS problem_name, $pc_sql
            C.title AS contest_name,
            C.is_official,
            COALESCE(R.testsets, CP.testsets) AS testsets,
            C.id AS contest_id, CP.id AS cp_id,
            CP.status, CP.code,
            CA.id AS ca_id
        FROM sources S
            INNER JOIN reqs R ON R.id = S.req_id
            INNER JOIN default_de DE ON DE.id = S.de_id
            INNER JOIN accounts A ON A.id = R.account_id
            INNER JOIN problems P ON P.id = R.problem_id
            INNER JOIN contests C ON C.id = R.contest_id
            INNER JOIN contest_problems CP ON CP.contest_id = C.id AND CP.problem_id = P.id
            INNER JOIN contest_accounts CA ON CA.contest_id = C.id AND CA.account_id = A.id
        WHERE req_id IN ($req_id_list)~, { Slice => {} });
    $dbh->{ib_enable_utf8} = 1; # Resume "normal" operation.

    # User must be either jury or request owner to access a request.
    # Cache is_jury_in_contest since it requires a database request.
    my %jury_cache;
    my $is_jury_cached = sub {
        $jury_cache{$_[0]} //= is_jury_in_contest(contest_id => $_[0]) ? 1 : 0
    };
    $result = [ grep {
        ($_->{is_jury} = $is_jury_cached->($_->{contest_id})) ||
        ($_->{account_id} == $uid || 0) } @$result
    ];

    my $official = $p{get_source} && CATS::Contest::current_official;
    $official = 0 if $official && $is_jury_cached->($official->{id});
    my $se = encoding_param('src_enc', 'WINDOWS-1251');

    for my $r (@$result) {
        $_ = Encode::decode_utf8($_) for @$r{grep /_name$/, keys %$r};
        $r = {
            %$r, state_to_display($r->{state}),
            CATS::IP::linkify_ip(CATS::IP::filter_ip $r->{last_ip}),
            href_stats => url_f('user_stats', uid => $r->{account_id}),
            href_send_message => url_f('send_message_box', caid => $r->{ca_id}),
        };
        # Just hour and minute from testing start and finish timestamps.
        ($r->{"${_}_short"} = $r->{$_}) =~ s/^(.*)\s+(\d\d:\d\d)\s*$/$2/
            for qw(test_time result_time);
        get_nearby_attempt($r, 'prev', '<', 'DESC', 1);
        get_nearby_attempt($r, 'next', '>', 'ASC', 0);
        # During the official contest, viewing sources from other contests
        # is disallowed to prevent cheating.
        if ($official && $official->{id} != $r->{contest_id}) {
            $r->{src} = res_str(138, $official->{title});
        }
        elsif ($p{encode_source}) {
            if (encodings()->{$se} && $r->{file_name} !~ m/\.zip$/) {
                Encode::from_to($r->{src}, $se, 'utf-8');
                $r->{src} = Encode::decode_utf8($r->{src});
            }
        }
        $r->{status_name} = problem_status_names->{$r->{status}};
    }

    return ref $rid ? $result : $result->[0];
}

sub build_title_suffix {
    my ($si) = @_;
    my %fn;
    $fn{$_->{file_name}}++ for @$si;
    join ',', map $_ . ($fn{$_} > 1 ? "*$fn{$_}" : ''), sort keys %fn;
}

sub sources_info_param {
    $t->param(
        title_suffix => build_title_suffix($_[0]),
        sources_info => $_[0],
    );
}

sub run_details_frame {
    init_template('run_details.html.tt');

    my $rid = url_param('rid') or return;
    my $rids = [ grep /^\d+$/, split /,/, $rid ];
    my $sources_info = get_sources_info(request_id => $rids, partial_checker => 1) or return;

    my @runs;
    my $contest = { id => 0 };
    for (@$sources_info) {
        if ($_->{is_jury} && param('retest')) {
            enforce_request_state(
                request_id => $_->{req_id},
                state => $cats::st_not_processed,
                # Insert NULL into database to be replaced with contest-default testset.
                testsets => param('testsets') || undef,
                judge_id => (param('set_judge') && param('judge') ? param('judge') : undef));
            $_ = get_sources_info(request_id => $_->{req_id}, partial_checker => 1) or next;
        }

        source_links($_);
        $contest = get_contest_info($_, $_->{is_jury} && !url_param('as_user'))
            if $_->{contest_id} != $contest->{id};
        push @runs,
            $_->{state} == $cats::st_compilation_error ?
            { get_log_dump($_->{req_id}, 1) } : get_run_info($contest, $_);
    }
    sources_info_param($sources_info);
    $t->param(runs => \@runs);
}

sub save_visualizer {
    my ($data, $lfname, $pid, $hash) = @_;

    ensure_problem_hash($pid, \$hash);

    my $fname = "vis/${hash}_$lfname";
    my $fpath = CATS::Misc::downloads_path . $fname;
    -f $fpath or CATS::BinaryFile::save($fpath, $data);
    return CATS::Misc::downloads_url . $fname;
}

sub visualize_test_frame {
    init_template('visualize_test.html.tt');

    $uid or return;
    my $rid = url_param('rid') or return;
    my $vid = url_param('vid') or return;
    my $test_rank = url_param('test_rank') or return;

    $dbh->selectrow_array(q~
        SELECT CA.is_jury
        FROM reqs R
        INNER JOIN contest_accounts CA ON CA.contest_id = r.contest_id
        INNER JOIN accounts A ON A.id = CA.account_id
        WHERE R.id = ? AND A.id = ?~, undef,
        $rid, $uid) or return;

    my $visualizer = $dbh->selectrow_hashref(q~
        SELECT PS.src, PS.fname, P.id AS problem_id, P.hash
        FROM problem_sources PS
        INNER JOIN problems P ON PS.problem_id = P.id
        INNER JOIN reqs R ON R.problem_id = P.id
        WHERE R.id = ? AND PS.id = ? AND PS.stype = ?~, { Slice => {} },
        $rid, $vid, $cats::visualizer) or return;

    my @imports_js = ($dbh->selectall_array(q~
        SELECT PS.src, PS.fname, PS.problem_id, P.hash
        FROM problem_sources_import PSI
        INNER JOIN problem_sources PS ON PS.guid = PSI.GUID
        INNER JOIN problems P ON P.id = PS.problem_id
        WHERE PSI.problem_id = ? AND PS.stype = ?~, { Slice => {} },
        $visualizer->{problem_id}, $cats::visualizer_module), $visualizer);

    my $script_srcs_links = [ map save_visualizer($_->{src}, $_->{fname}, $_->{problem_id}, $_->{hash}), @imports_js ];

    my $input_file = $dbh->selectrow_array(q~
        SELECT T.in_file
        FROM tests T
        INNER JOIN reqs R ON R.problem_id = T.problem_id
        WHERE R.id = ? AND T.rank = ?~, undef,
        $rid, $test_rank) or return;

    $t->param(import_scripts => $script_srcs_links);
    $t->param(input_file => $input_file);
}

sub view_source_frame {
    init_template('view_source.html.tt');
    my $rid = url_param('rid') or return;
    my $sources_info = get_sources_info(request_id => $rid, get_source => 1, encode_source => 1);
    $sources_info or return;

    my $replace_source = param('replace_source');
    my $de_id = param('de_id');
    my $set = join ', ', ($replace_source ? 'src = ?' : ()) , ($de_id ? 'de_id = ?' : ());
    if ($sources_info->{is_jury} && $set) {
        my $s = $dbh->prepare(qq~
            UPDATE sources SET $set WHERE req_id = ?~);
        my $i = 0;
        if ($replace_source) {
            my $src = upload_source('replace_source') or return;
            $s->bind_param(++$i, $src, { ora_type => 113 } ); # blob
            $sources_info->{src} = $src;
        }
        $s->bind_param(++$i, $de_id) if $de_id;
        $s->bind_param(++$i, $sources_info->{req_id});
        $s->execute;
        $dbh->commit;
    }
    if ($sources_info->{file_name} =~ m/\.zip$/) {
        $sources_info->{src} = sprintf 'ZIP, %d bytes', length ($sources_info->{src});
    }
    source_links($sources_info);
    /^[a-z]+$/i and $sources_info->{syntax} = $_ for param('syntax');
    $sources_info->{src_lines} = [ map {}, split("\n", $sources_info->{src}) ];
    sources_info_param([ $sources_info ]);

    if ($sources_info->{is_jury}) {
        my $de_list = CATS::DevEnv->new($dbh, active_only => 1);
        if ($de_id) {
            $sources_info->{de_id} = $de_id;
            $sources_info->{de_name} = $de_list->by_id($de_id)->{description};
        }
        $t->param(de_list => [
            map {
                de_id => $_->{id},
                de_name => $_->{description},
                selected => $_->{id} == $sources_info->{de_id},
            }, @{$de_list->{_de_list}}
        ]);
    }
}

sub download_source_frame {
    my $rid = url_param('rid') or return;
    my $si = get_sources_info(request_id => $rid, get_source => 1, encode_source => 1);

    unless ($si) {
        init_template('view_source.html.tt');
        return;
    }

    $si->{file_name} =~ m/\.([^.]+)$/;
    my $ext = $1 || 'unknown';
    content_type($ext eq 'zip' ? 'application/zip' : 'text/plain', 'UTF-8');
    headers('Content-Disposition' => "inline;filename=$si->{req_id}.$ext");
    CATS::Web::print(Encode::encode_utf8($si->{src}));
}

sub try_set_state {
    my ($si, $rid) = @_;
    defined param('set_state') or return;
    my $state = {
        not_processed =>         $cats::st_not_processed,
        awaiting_verification => $cats::st_awaiting_verification,
        accepted =>              $cats::st_accepted,
        wrong_answer =>          $cats::st_wrong_answer,
        presentation_error =>    $cats::st_presentation_error,
        time_limit_exceeded =>   $cats::st_time_limit_exceeded,
        memory_limit_exceeded => $cats::st_memory_limit_exceeded,
        runtime_error =>         $cats::st_runtime_error,
        compilation_error =>     $cats::st_compilation_error,
        security_violation =>    $cats::st_security_violation,
        ignore_submit =>         $cats::st_ignore_submit,
        idleness_limit_exceeded=>$cats::st_idleness_limit_exceeded,
        manually_rejected =>     $cats::st_manually_rejected,
    }->{param('state')};
    defined $state or return;

    my $failed_test = sprintf '%d', param('failed_test') || '0';
    my $points = sprintf '%d', param('points') || '0';
    enforce_request_state(
        request_id => $rid, failed_test => $failed_test, state => $state, points => $points);
    my %st = state_to_display($state);
    while (my ($k, $v) = each %st) {
        $si->{$k} = $v;
    }
    $si->{failed_test} = $failed_test;
    1;
}

sub run_log_frame {
    init_template('run_log.html.tt');
    my $rid = url_param('rid') or return;

    my $si = get_sources_info(request_id => $rid)
        or return;
    $si->{is_jury} or return;

    my $can_delete = !$si->{is_official} || $is_root;
    $t->param(can_delete => $can_delete);
    if (param('delete') && $can_delete) {
        $dbh->do(q~
            DELETE FROM reqs WHERE id = ?~, undef,
            $rid);
        $dbh->commit;
        return;
    }

    # Reload problem after the successful state change.
    $si = get_sources_info(request_id => $rid)
        if try_set_state($si, $rid);
    sources_info_param([ $si ]);

    source_links($si);
    $t->param(get_log_dump($rid));

    my $tests = $dbh->selectcol_arrayref(qq~
        SELECT rank FROM tests WHERE problem_id = ? ORDER BY rank~, undef,
        $si->{problem_id});
    $t->param(tests => [ map {test_index => $_}, @$tests ]);
}

sub diff_runs_frame {
    my ($p) = @_;
    init_template('diff_runs.html.tt');
    $p->{r1} && $p->{r2} or return;

    my $si = get_sources_info(
        request_id => [ $p->{r1}, $p->{r2} ], get_source => 1) or return;
    @$si == 2 or return;

    source_links($_) for @$si;

    for my $info (@$si) {
        $info->{lines} = [ split "\n", $info->{src} ];
        s/\s*$// for @{$info->{lines}};
    }

    my @diff;

    my $SL = sub { $si->[$_[0]]->{lines}->[$_[1]] || '' };

    my $match = sub { push @diff, { line => $SL->(0, $_[0]) }; };
    my $only_a = sub { push @diff, { class => 'diff_only_a', line => $SL->(0, $_[0]) }; };
    my $only_b = sub { push @diff, { class => 'diff_only_b', line => $SL->(1, $_[1]) }; };

    Algorithm::Diff::traverse_sequences(
        $si->[0]->{lines},
        $si->[1]->{lines},
        {
            MATCH     => $match,  # callback on identical lines
            DISCARD_A => $only_a, # callback on A-only
            DISCARD_B => $only_b, # callback on B-only
        }
    );

    sources_info_param($si);
    $t->param(diff_lines => \@diff);
}

1;
