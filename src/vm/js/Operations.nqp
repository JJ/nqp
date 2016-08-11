class QAST::OperationsJS {
    my %ops;

    my %inlinable;

    my %result_type;

    sub add_op($op, $cb, :$inlinable = 1) {
        %ops{$op} := $cb;
        %inlinable{$op} := $inlinable;
    }

    sub op_template($comp, $node, $return_type, @argument_types, $cb, :$ctx, :$cps, :$decont) {
        my @exprs;
        my @setup;

        my @decont;
        if nqp::islist($decont) {
            for $decont -> $index {
                @decont[$index] := 1;
            }
        }
        elsif nqp::defined($decont) {
            @decont[$decont] := 1;
        }

        if $node.list > @argument_types {
            nqp::die("{+$node.list} arguments for {$node.op}, the maximum is {+@argument_types}");
        } 

        if $ctx {
          @exprs.push($*CTX);
        }

        my $i := 0;
        for $node.list -> $arg {
            my $chunk := $comp.as_js($arg, :want(@argument_types[$i]));
            @exprs.push(@decont[$i] ?? "nqp.op.decont($*CTX, {$chunk.expr})" !! $chunk.expr);
            @setup.push($chunk);
            $i := $i + 1;
        }

        if $cps {
            my $cont := $comp.unique_var('cont');
            my $result := $comp.unique_var('result');
            @exprs.push($cont);
            @setup.push('return ' ~ $cb(|@exprs, :$cps) ~ ";\n");
            ChunkCPS.new($return_type, $result, @setup, $cont, :$node);
        }
        else {
            Chunk.new($return_type, $cb(|@exprs), @setup, :$node);
        }
    }

    sub runtime_op($op, @argument_types) {
        sub (*@args, :$cps) {
            "nqp.op.$op{$cps ?? 'CPS' !! ''}({nqp::join(',', @args)})";
        }
    }

    sub add_simple_op($op, $return_type, @argument_types, $cb = runtime_op($op, @argument_types), :$sideffects, :$ctx, :$required_cps, :$cps_aware, :$inlinable = 1, :$decont) {

        add_op($op, sub ($comp, $node, :$want, :$cps) {
            my $use_cps := $required_cps || ($cps_aware && $cps);
            my $chunk := op_template($comp, $node, $return_type, @argument_types, $cb, :$ctx, :cps($use_cps), :$decont);
            ($sideffects && !$use_cps) ?? $comp.stored_result($chunk, :$want) !! $chunk;
        }, :$inlinable);

        set_op_result_type($op, $return_type);
    }

    sub add_hll_op($op) {
        %ops{$op} := sub ($comp, $node, :$want, :$cps) {
            my @operands := $node.list;
            $comp.as_js(QAST::Op.new(
                :op('call'),
                :returns(str),
                QAST::Op.new(
                    :op('gethllsym'),
                    QAST::SVal.new( :value('nqp') ),
                    QAST::SVal.new( :value($op) )
                ),
                |@operands ), :$want, :$cps);
        };
    }

    sub add_infix_op($op, $left_type, $syntax, $right_type, $return_type) {
        %ops{$op} := sub ($comp, $node, :$want, :$cps) {
            my $left  := $comp.as_js($node[0], :want($left_type), :$cps);
            my $right := $comp.as_js($node[1], :want($right_type), :$cps);
            $comp.cpsify_chunk(Chunk.new($return_type, "({$left.expr} $syntax {$right.expr})", [$left, $right], :$node));
        };
    }

    # Sets op native result type at a core level.
    sub set_op_result_type(str $op, $type) {
        if $type == $T_INT {
            %result_type{$op} := int;
        }
        elsif $type == $T_NUM {
            %result_type{$op} := num;
        }
        elsif $type == $T_STR {
            %result_type{$op} := str;
        }
    }

    # Sets returns on an op node if we it has a native result type.
    method attach_result_type($hll, $node) {
        my $op := $node.op;
        if nqp::existskey(%result_type, $op) {
            $node.returns(%result_type{$op});
        }
    }

    method is_inlinable(str $hll, str $op) {
        return %inlinable{$op};
    }

    # The code being compiled has access to this class as "nqp::getcomp('QAST').operations".
    # We expose &add_op as a method so that it can call it.
    method add_op($op, $cb, :$inlinable = 1) {
        add_op($op, $cb, :$inlinable);
    }

    method add_simple_op(*@args, *%args, :$inlinable) {
        add_simple_op(|@args, |%args, :$inlinable);
    }

    method OBJ() { $T_OBJ }
    method INT() { $T_INT }
    method STR() { $T_STR }
    method NUM() { $T_NUM }
    method BOOL() { $T_BOOL }
    method VOID() { $T_VOID }

    method new_chunk(*@args) { Chunk.new(|@args) }

    add_simple_op('setcontspec', $T_OBJ, [$T_OBJ, $T_STR, $T_OBJ], :sideffects, :decont(0));
    add_simple_op('assign',  $T_OBJ, [$T_OBJ, $T_OBJ], sub ($cont, $value) {"$cont.\$\$assign({$*CTX},$value)"}, :sideffects, :decont(1));
    add_simple_op('assignunchecked',  $T_OBJ, [$T_OBJ, $T_OBJ], sub ($cont, $value) {"$cont.\$\$assignunchecked({$*CTX},$value)"}, :sideffects);
    add_simple_op('decont', $T_OBJ, [$T_OBJ], :ctx);
    add_simple_op('iscont', $T_INT, [$T_OBJ]);
    add_simple_op('isrwcont', $T_INT, [$T_OBJ]);

    add_simple_op('iscont_i', $T_INT, [$T_OBJ]);
    add_simple_op('iscont_s', $T_INT, [$T_OBJ]);
    add_simple_op('iscont_n', $T_INT, [$T_OBJ]);

    add_infix_op('add_n', $T_NUM, '+', $T_NUM, $T_NUM);
    add_infix_op('sub_n', $T_NUM, '-', $T_NUM, $T_NUM);
    add_infix_op('mul_n', $T_NUM, '*', $T_NUM, $T_NUM);
    # TODO - think about divide by zero
    add_infix_op('div_n', $T_NUM, '/', $T_NUM, $T_NUM);
    add_infix_op('mod_n', $T_NUM, '%', $T_NUM, $T_NUM);

    add_simple_op('mod_n', $T_NUM, [$T_NUM, $T_NUM]);


    add_simple_op('neg_n', $T_NUM, [$T_NUM], sub ($num) {"(-$num)"});
    add_simple_op('neg_i', $T_INT, [$T_INT], sub ($num) {"(-$num)"});

    add_infix_op('concat', $T_STR, '+', $T_STR, $T_STR);

    for ['_i', $T_INT, '_n', $T_NUM, '_s', $T_STR] -> $suffix, $type {
        add_infix_op('isle' ~ $suffix, $type, '<=', $type, $T_BOOL);
        add_infix_op('islt' ~ $suffix, $type, '<', $type, $T_BOOL);
        add_infix_op('isgt' ~ $suffix, $type, '>', $type, $T_BOOL);
        add_infix_op('isge' ~ $suffix, $type, '>=', $type, $T_BOOL);
        add_infix_op('iseq' ~ $suffix, $type, '==', $type, $T_BOOL);
        add_infix_op('isne' ~ $suffix, $type, '!=', $type, $T_BOOL);
    }

    add_simple_op('inf', $T_NUM, [], sub () {"Infinity"});
    add_simple_op('neginf', $T_NUM, [], sub () {"(-Infinity)"});
    add_simple_op('nan', $T_NUM, [], sub () {"NaN"});
    add_simple_op('isnanorinf', $T_INT, [$T_NUM]);

    add_infix_op('bitor_i', $T_INT, '|', $T_INT, $T_INT);
    add_infix_op('bitand_i', $T_INT, '&', $T_INT, $T_INT);
    add_infix_op('bitxor_i', $T_INT, '^', $T_INT, $T_INT);
    add_infix_op('bitshiftl_i', $T_INT, '<<', $T_INT, $T_INT);
    add_infix_op('bitshiftr_i', $T_INT, '>>', $T_INT, $T_INT);

    add_simple_op('bitor_s', $T_STR, [$T_STR, $T_STR]);
    add_simple_op('bitand_s', $T_STR, [$T_STR, $T_STR]);
    add_simple_op('bitxor_s', $T_STR, [$T_STR, $T_STR]);

    add_simple_op('bitneg_i', $T_INT, [$T_INT], sub ($n) {"(~$n)"});

    add_infix_op('eqaddr', $T_OBJ, '===', $T_OBJ, $T_BOOL);

    # Integer arithmetic
    add_simple_op('add_i', $T_INT, [$T_INT, $T_INT], sub ($a, $b) {"(($a + $b) | 0)"});
    add_simple_op('sub_i', $T_INT, [$T_INT, $T_INT], sub ($a, $b) {"(($a - $b) | 0)"});
    add_simple_op('div_i', $T_INT, [$T_INT, $T_INT], sub ($a, $b) {"(($a / $b) | 0)"});
    add_simple_op('mod_i', $T_INT, [$T_INT, $T_INT], sub ($a, $b) {"(($a % $b) | 0)"});
    add_simple_op('mul_i', $T_INT, [$T_INT, $T_INT], sub ($a, $b) {"Math.imul($a,$b)"});
    add_simple_op('pow_i', $T_INT, [$T_INT, $T_INT], sub ($a, $b) {"(Math.pow($a,$b)|0)"});
    add_simple_op('gcd_i', $T_INT, [$T_INT, $T_INT]);
    add_simple_op('lcm_i', $T_INT, [$T_INT, $T_INT]);

    add_simple_op('istype', $T_BOOL, [$T_OBJ, $T_OBJ], sub ($value, $type) {"($value instanceof $type.constructor)"});


    add_op('chain', sub ($comp, $node, :$want, :$cps) {
        my $ret := $*BLOCK.add_tmp;

        my sub is_chain($part) {
            $part ~~ QAST::Op && $part.op eq 'chain';
        }

        my sub chain_part($part) {
            if is_chain($part) {
                my $callee := $comp.as_js(QAST::Var.new(:name($part.name),:scope('lexical')), :want($T_OBJ));
                my $left := chain_part($part[0]);
                my $right := $comp.as_js($part[1], :want($T_OBJ));
                my @setup;

                @setup.push($left);

                @setup.push("if (nqp.toBool($ret, $*CTX)) \{\n") if is_chain($part[0]);
                @setup.push($callee);
                @setup.push($right);
                @setup.push("$ret = {$callee.expr}.\$\$call($*CTX, null, {$left.expr}, {$right.expr});\n");
                @setup.push("\}") if is_chain($part[0]);

                Chunk.new($T_OBJ, $right.expr, @setup, :node($part));
            }
            else {
                $comp.as_js($part, :want($T_OBJ));
            }
        }

        Chunk.new($T_OBJ, $ret, [chain_part($node)]);
    });

    add_simple_op('clone', $T_OBJ, [$T_OBJ], :decont(0));

    my sub static_attr($node) {
        my int $hint := -1;
        if $node[1].has_compile_time_value && nqp::istype($node[2], QAST::SVal) {
            $hint := nqp::hintfor($node[1].compile_time_value, $node[2].value);
        }

        $hint != -1 ?? 'attr$' ~ $hint !! NQPMu;
    }

    # TODO optimize cases where the class and the attribute are constants
    for ['', $T_OBJ, '_i', $T_INT, '_n', $T_NUM, '_s', $T_STR] -> $suffix, $type {
        add_op('bindattr' ~ $suffix, sub ($comp, $node, :$want, :$cps) {
            my $obj := $comp.as_js(:want($T_OBJ), $node[0]);
            my $value := $comp.as_js(:want($type), $node[3]);
            if static_attr($node) -> $attr {
                $comp.stored_result(Chunk.new($type,
                    "({$obj.expr}\.$attr = {$value.expr})",
                [$obj, $value]), :$want);
            }
            else {
                my $classHandle := $comp.as_js(:want($T_OBJ), $node[1]);
                my $attrName := $comp.as_js(:want($T_STR), $node[2]);

                $comp.stored_result(Chunk.new($type,
                    "{$obj.expr}\.\$\$bindattr({$classHandle.expr}, {$attrName.expr}, {$value.expr})",
                [$obj, $classHandle, $attrName, $value]), :$want);
            }

        });

        add_op('getattr' ~ $suffix, sub ($comp, $node, :$want, :$cps) {
            my $obj := $comp.as_js(:want($T_OBJ), $node[0]);
            if static_attr($node) -> $attr {
                Chunk.new($type, "({$obj.expr}\.$attr)", [$obj]);
            }
            else {
                my $classHandle := $comp.as_js(:want($T_OBJ), $node[1]);
                my $attrName := $comp.as_js(:want($T_STR), $node[2]);

                Chunk.new($type, "{$obj.expr}\.\$\$getattr({$classHandle.expr}, {$attrName.expr})",
                    [$obj, $classHandle, $attrName]);
            }
        });
    }

    add_simple_op('hintfor', $T_INT, [$T_OBJ, $T_STR]);


    add_hll_op('sprintf');
    add_hll_op('sprintfdirectives');
    add_hll_op('sprintfaddargumenthandler');

    add_simple_op('setinvokespec', $T_OBJ, [$T_OBJ, $T_OBJ, $T_STR, $T_OBJ], :sideffects, :decont(0));
    add_simple_op('setboolspec', $T_OBJ, [$T_OBJ, $T_INT, $T_OBJ], :sideffects, :decont(0));

    sub add_cmp_op($op, $type) {
        add_simple_op($op, $T_INT, [$type, $type], sub ($a, $b) {
            "($a < $b ? -1 : ($a == $b ? 0 : 1))"
        });
    }

    add_simple_op('reprname', $T_STR, [$T_OBJ], :decont(0));
    add_simple_op('newtype', $T_OBJ, [$T_OBJ, $T_STR], :sideffects, :decont(0));

    add_cmp_op('cmp_i', $T_INT);
    add_cmp_op('cmp_n', $T_NUM);
    add_cmp_op('cmp_s', $T_STR);

    for <preinc predec> -> $op {
        add_op($op, sub ($comp, $node, :$want, :$cps) {
            my $action := $op eq 'preinc' ?? 'add_i' !! 'sub_i';
            $comp.as_js(
                QAST::Op.new(
                    :op('bind'),
                    $node[0],
                    QAST::Op.new(:op($action),$node[0],QAST::IVal.new(:value(1)))
                ),
                :$want,
                :$cps
            );
        });
    }

    for <postinc postdec> -> $op {
        add_op($op, sub ($comp, $node, :$want, :$cps) {
            # TODO CPS
            my $tmp := $*BLOCK.add_tmp();
            my $var := $comp.as_js($node[0], :want($T_INT));
            my $action := $op eq 'postinc' ?? 'add_i' !! 'sub_i';
            my $do_action := $comp.as_js(
                QAST::Op.new(
                    :op('bind'),
                    $node[0],
                    QAST::Op.new(:op($action),$node[0],QAST::IVal.new(:value(1)))
                ),
                :want($T_VOID)
            );
            Chunk.new($T_INT, $tmp, [$var, "$tmp = {$var.expr};\n", $do_action]);
       });
    }

    add_simple_op('isstr', $T_BOOL, [$T_OBJ], sub ($obj) {"(typeof $obj == 'string')"}, :decont(0));
    add_simple_op('isint', $T_INT, [$T_OBJ], :decont(0));
    add_simple_op('isnum', $T_INT, [$T_OBJ], :decont(0));

    add_simple_op('chars', $T_INT, [$T_STR], sub ($string) {"$string.length"});

    add_simple_op('join', $T_STR, [$T_STR, $T_OBJ], sub ($delim, $list) {"$list.\$\$join($delim)"});

    add_simple_op('index', $T_INT, [$T_STR, $T_STR, $T_INT], sub ($string, $pattern, $from?) {
        nqp::defined($from) ?? "($from > $string.length ? -1 : $string.indexOf($pattern,$from))" !! "$string.indexOf($pattern)";
    });

    add_simple_op('rindex', $T_INT, [$T_STR, $T_STR, $T_INT], sub ($string, $pattern, $from?) {
        nqp::defined($from) ?? "($from > $string.length ? -1 : $string.lastIndexOf($pattern,$from))" !! "$string.lastIndexOf($pattern)";
    });

    add_simple_op('substr', $T_STR, [$T_STR, $T_INT, $T_INT], sub ($string, $start, $length?) {
        nqp::defined($length) ?? "$string.substr($start,$length)" !! "$string.substr($start)";
    });

    add_simple_op('replace', $T_STR, [$T_STR, $T_INT, $T_INT, $T_STR]);

    add_simple_op('eqat', $T_BOOL, [$T_STR, $T_STR, $T_INT], sub ($haystack, $needle, $offset) {
        "($haystack.substr($offset, $needle.length) === $needle)"
    });



    add_simple_op('chr', $T_STR, [$T_INT], sub ($code) {"String.fromCharCode($code)"});

    add_simple_op('lc', $T_STR, [$T_STR], sub ($string) {"$string.toLowerCase()"});
    add_simple_op('uc', $T_STR, [$T_STR], sub ($string) {"$string.toUpperCase()"});

    add_simple_op('flip', $T_STR, [$T_STR], sub ($string) {"$string.split('').reverse().join('')"});

    add_simple_op('ord', $T_INT, [$T_STR, $T_INT], sub ($string, $pos='0') {"$string.charCodeAt($pos)"});
    %ops<ordat> := %ops<ord>;

    add_simple_op('ordbaseat', $T_INT, [$T_STR, $T_INT]);

    add_simple_op('getcodelocation', $T_OBJ, [$T_OBJ]);

    add_simple_op('null', $T_OBJ, [], sub () {"null"});

    add_simple_op('isnull', $T_BOOL, [$T_OBJ], sub ($obj) {"($obj === null)"});

    add_simple_op('null_s', $T_STR, [], sub () {"null"});
    add_simple_op('isnull_s', $T_BOOL, [$T_STR], sub ($obj) {"($obj === null)"});

    add_simple_op('time_n', $T_NUM, [], sub () {"(new Date().getTime() / 1000)"}, :sideffects);
    add_simple_op('time_i', $T_NUM, [], sub () {"Math.floor(new Date().getTime() / 1000)"}, :sideffects);

    add_simple_op('escape', $T_STR, [$T_STR]);
    add_simple_op('x', $T_STR, [$T_STR, $T_INT], sub ($what, $times) {"$what.repeat($times)"});

    add_simple_op('getcomp', $T_OBJ, [$T_STR], :sideffects);

    add_simple_op('say', $T_STR, [$T_STR], :sideffects);
    add_simple_op('print', $T_STR, [$T_STR], :sideffects);

    add_simple_op('getstderr', $T_OBJ, [], :sideffects);
    add_simple_op('getstdout', $T_OBJ, [], :sideffects);
    add_simple_op('getstdin', $T_OBJ, [], :sideffects);

    add_simple_op('open', $T_OBJ, [$T_STR, $T_STR], :sideffects);

    add_simple_op('tellfh', $T_INT, [$T_OBJ], :sideffects);
    add_simple_op('seekfh', $T_INT, [$T_OBJ, $T_INT, $T_INT], :ctx, :sideffects);
    add_simple_op('eoffh', $T_INT, [$T_OBJ], :sideffects);
    add_simple_op('readlinefh', $T_STR, [$T_OBJ], :sideffects);
    add_simple_op('readcharsfh', $T_STR, [$T_OBJ, $T_INT], :sideffects);
    add_simple_op('readlinechompfh', $T_STR, [$T_OBJ], :sideffects);
    add_simple_op('readallfh', $T_STR, [$T_OBJ], :sideffects);
    add_simple_op('printfh', $T_OBJ, [$T_OBJ, $T_STR], :sideffects);
    add_simple_op('sayfh', $T_OBJ, [$T_OBJ, $T_STR], :sideffects);
    add_simple_op('flushfh', $T_OBJ, [$T_OBJ], :sideffects);
    add_simple_op('closefh', $T_OBJ, [$T_OBJ], :sideffects);
    add_simple_op('closefh_i', $T_INT, [$T_OBJ], :sideffects);
    add_simple_op('isttyfh', $T_INT, [$T_OBJ]);
    add_simple_op('setinputlinesep', $T_OBJ, [$T_OBJ, $T_STR], :sideffects);
    add_simple_op('setinputlineseps', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);

    add_simple_op('bootarray', $T_OBJ, []);

    add_simple_op('getpid', $T_INT, []);

    add_simple_op('exit', $T_VOID, [$T_INT], :sideffects);


    add_simple_op('symlink', $T_VOID, [$T_STR, $T_STR], :sideffects);
    add_simple_op('link', $T_VOID, [$T_STR, $T_STR], :sideffects);
    add_simple_op('unlink', $T_VOID, [$T_STR], :sideffects);
    add_simple_op('setencoding', $T_VOID, [$T_OBJ, $T_STR], :sideffects);

    add_simple_op('readlink', $T_STR, [$T_STR]);

    add_simple_op('chdir', $T_VOID, [$T_STR], :sideffects);
    add_simple_op('rmdir', $T_VOID, [$T_STR], :sideffects);
    add_simple_op('mkdir', $T_VOID, [$T_STR, $T_INT], :sideffects);

    add_simple_op('chmod', $T_VOID, [$T_STR, $T_INT], :sideffects);

    add_simple_op('getenvhash', $T_OBJ, [], :sideffects);
    add_simple_op('cwd', $T_STR, [], :sideffects);

    add_simple_op('shell', $T_VOID, [$T_STR, $T_STR, $T_OBJ, $T_OBJ, $T_OBJ, $T_OBJ, $T_INT], :sideffects);
    add_simple_op('syncpipe', $T_OBJ, [], :sideffects);

    add_simple_op('spawn', $T_VOID, [$T_OBJ, $T_STR, $T_OBJ, $T_OBJ, $T_OBJ, $T_OBJ, $T_INT], :sideffects);


    add_simple_op('sha1', $T_STR, [$T_STR]);


    add_simple_op('isinvokable', $T_INT, [$T_OBJ]);

    add_simple_op('encode', $T_OBJ, [$T_STR, $T_STR, $T_OBJ], :sideffects);
    add_simple_op('decode', $T_STR, [$T_OBJ, $T_STR]);

    add_simple_op('gethostname', $T_STR, [$T_STR]);

    # XXX explicit takeclosure will go away under new model (which nqp-m uses); for now, no-op it.
    add_op('takeclosure', sub ($comp, $node, :$want, :$cps) {
        $comp.as_js($node[0], :want($want), :$cps);
    });

    # TODO decont
    add_op('istrue', sub ($comp, $node, :$want, :$cps) {
        $comp.as_js($node[0], :want($T_BOOL), :$cps);
    });
    add_op('stringify', sub ($comp, $node, :$want, :$cps) {
        $comp.as_js($node[0], :want($T_STR), :$cps);
    });
    add_op('numify', sub ($comp, $node, :$want, :$cps) {
        $comp.as_js($node[0], :want($T_NUM), :$cps);
    });

    add_simple_op('falsey', $T_BOOL, [$T_BOOL], sub ($boolified) {"(!$boolified)"});

    add_simple_op('not_i', $T_BOOL, [$T_INT], sub ($int) {"(!$int)"});

    add_op('locallifetime', sub ($comp, $node, :$want, :$cps) {
        $comp.as_js($node[0], :want($want), :$cps);
    });

    add_op('bind', sub ($comp, $node, :$want, :$cps) {
        my @children := $node.list;
        if +@children != 2 {
            nqp::die("A 'bind' op must have exactly two children");
        }
        unless nqp::istype(@children[0], QAST::Var) {
            nqp::die("First child of a 'bind' op must be a QAST::Var");
        }

        my $*BINDVAL := @children[1];
        $comp.as_js(@children[0], :want($want), :$cps);
    });


    add_op('bindkey', sub ($comp, $node, :$want, :$cps) {
        $comp.bind_key($node[0], $node[1], $node[2], :$cps);
    });
    add_op('bindpos', sub ($comp, $node, :$want, :$cps) {
        $comp.bind_pos($node[0], $node[1], $node[2], :$cps);
    });

    for ['_i', $T_INT, '', $T_OBJ, '_s', $T_STR, '_n', $T_NUM] -> $suffix, $type {
        add_op('list' ~ $suffix, sub ($comp, $node, :$want, :$cps) {
           # TODO CPS
           my @setup;
           my @exprs;

           my $list := $*BLOCK.add_tmp();

           for $node.list -> $elem {
               my $chunk := $comp.as_js($elem, :want($type));
               @setup.push($chunk);
               @exprs.push($chunk.expr);
           }

           @setup.push("$list = new nqp.NQPArray([" ~ nqp::join(',', @exprs) ~ "]);\n");

           $comp.cpsify_chunk(Chunk.new($T_OBJ, $list , @setup, :$node));
        });

        if $type != $T_OBJ {
            add_simple_op('bindpos' ~ $suffix, $type, [$T_OBJ, $T_INT, $type], sub ($list, $index, $value) {"$list.\$\$bindpos($index, $value)"}, :sideffects);
            add_simple_op('atpos' ~ $suffix, $type, [$T_OBJ, $T_INT], sub ($list, $index) {"$list.\$\$atpos$suffix($index)"});

        }
        
        add_simple_op('pop' ~ $suffix, $type, [$T_OBJ], sub ($array) {"$array.\$\$pop()"}, :sideffects);
        add_simple_op('push' ~ $suffix, $type, [$T_OBJ, $type], sub ($array, $elem) {"$array.\$\$push($elem)"}, :sideffects);
        add_simple_op('unshift' ~ $suffix, $type, [$T_OBJ, $type], sub ($array, $elem) {"$array.\$\$unshift($elem)"}, :sideffects);
        add_simple_op('shift' ~ $suffix, $type, [$T_OBJ], sub ($array) {"$array.\$\$shift()"}, :sideffects);
 

        add_simple_op('atposnd' ~ $suffix, $type, [$T_OBJ, $T_OBJ]);
        add_simple_op('atpos2d' ~ $suffix, $type, [$T_OBJ, $T_INT, $T_INT, $type],  :sideffects);
        add_simple_op('atpos3d' ~ $suffix, $type, [$T_OBJ, $T_INT, $T_INT, $T_INT, $type], :sideffects);

        add_simple_op('bindposnd' ~ $suffix, $type, [$T_OBJ, $T_OBJ, $type], :sideffects);
        add_simple_op('bindpos2d' ~ $suffix, $type, [$T_OBJ, $T_INT, $T_INT, $type], :sideffects);
        add_simple_op('bindpos3d' ~ $suffix, $type, [$T_OBJ, $T_INT, $T_INT, $T_INT, $type], :sideffects);
    }

    add_simple_op('numdimensions', $T_INT, [$T_OBJ]);
    add_simple_op('dimensions', $T_OBJ, [$T_OBJ]);
    add_simple_op('setdimensions', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);

    add_op('hash', sub ($comp, $node, :$want, :$cps) {
        # TODO CPS
        my $hash := $*BLOCK.add_tmp();
        my @setup;
        @setup.push("$hash = nqp.hash();\n");
        for $node.list -> $key, $val {
            my $key_chunk := $comp.as_js($key, :want($T_STR));
            my $val_chunk := $comp.as_js($val, :want($T_OBJ));
            @setup.push($key_chunk);
            @setup.push($val_chunk);
            @setup.push("$hash.content.set({$key_chunk.expr}, {$val_chunk.expr});\n");
         }
         Chunk.new($T_OBJ, $hash , @setup , :$node);
    });
    add_simple_op('ishash', $T_INT, [$T_OBJ], :decont(0));


    add_op('call', :!inlinable, sub ($comp, $node, :$want, :$cps) {
        my $args := nqp::clone($node.list);

        my $callee := $node.name
            ?? $comp.as_js(QAST::Var.new(:name($node.name),:scope('lexical')), :want($T_OBJ))
            !! $comp.as_js(nqp::shift($args), :want($T_OBJ));


        my $call;


        if $cps {
            my $cont := $comp.unique_var('cont');
            my $result := $comp.unique_var('result');

            my $compiled_args := $comp.args($args, :$cont);

            my @setup;
            @setup.push($callee);

            if nqp::islist($compiled_args) {
                for $compiled_args -> $arg_group {
                    for $arg_group.setup -> $arg {
                        @setup.push($arg);
                    }
                }
                $compiled_args := $comp.merge_arg_groups($compiled_args);
                $call := '.$$applyCPS(';
            }
            else {
                for $compiled_args.setup -> $arg {
                    @setup.push($arg);
                }
                $call := '.$$callCPS(';
            }

            
            my $call_chunk := ChunkCPS.new($T_OBJ, $result, ['return ' ~ $callee.expr ~ $call ~ $compiled_args.expr ~ ");\n"], $cont);

            @setup.push($call_chunk);

            $comp.chunk_sequence($T_OBJ, @setup, :$node, :result_child(nqp::elems(@setup) - 1));
        }
        else {
            my $compiled_args := $comp.args($args);

            if nqp::islist($compiled_args) {
                $compiled_args := $comp.merge_arg_groups($compiled_args);
                $call := '.$$apply(';
            }
            else {
                $call := '.$$call(';
            }
            $comp.stored_result(
                Chunk.new($T_OBJ, $callee.expr ~ $call ~ $compiled_args.expr ~ ')' , [$callee, $compiled_args], :$node), :$want);
        }
    });

    %ops<callstatic> := %ops<call>;

    add_simple_op('serialize', $T_STR, [$T_OBJ, $T_OBJ], :sideffects);
    add_simple_op('scobjcount', $T_INT, [$T_OBJ]);
    add_simple_op('createsc', $T_OBJ, [$T_STR], :sideffects);
    add_simple_op('deserialize', $T_OBJ, [$T_STR, $T_OBJ, $T_OBJ, $T_OBJ, $T_OBJ], :sideffects);
    add_simple_op('scsetobj', $T_OBJ, [$T_OBJ, $T_INT, $T_OBJ], :sideffects);
    add_simple_op('scgetobj', $T_OBJ, [$T_OBJ, $T_INT], :sideffects);
    add_simple_op('scsetcode', $T_OBJ, [$T_OBJ, $T_INT, $T_OBJ], :sideffects);
    add_simple_op('setobjsc', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);
    add_simple_op('markcodestatic', $T_OBJ, [$T_OBJ], :sideffects);

    add_simple_op('freshcoderef', $T_OBJ, [$T_OBJ]);
    add_simple_op('markcodestub', $T_OBJ, [$T_OBJ], :sideffects);

    add_simple_op('scsetdesc', $T_STR, [$T_OBJ, $T_STR], :sideffects);
    add_simple_op('scgetdesc', $T_STR, [$T_OBJ]);

    add_simple_op('scgethandle', $T_STR, [$T_OBJ]);

    add_simple_op('getobjsc', $T_OBJ, [$T_OBJ]);
    add_simple_op('scgetobjidx', $T_INT, [$T_OBJ, $T_OBJ]);

    add_simple_op('pushcompsc', $T_OBJ, [$T_OBJ], :sideffects);
    add_simple_op('popcompsc', $T_OBJ, [], :sideffects);

    add_simple_op('getstaticcode', $T_OBJ, [$T_OBJ]);

    # Misc ops

    add_simple_op('backendconfig', $T_OBJ, []);

    # Ops for NFA

    add_simple_op('nfafromstatelist', $T_OBJ, [$T_OBJ, $T_OBJ], :ctx, :sideffects);
    add_simple_op('nfarunproto', $T_OBJ, [$T_OBJ, $T_STR, $T_INT], :sideffects);
    add_simple_op('nfarunalt', $T_OBJ, [$T_OBJ, $T_STR, $T_INT, $T_OBJ, $T_OBJ, $T_OBJ]);

    # TODO 
    # add_simple_op('nfatostatelist', $T_OBJ, [$T_OBJ]);

    add_op('callmethod', sub ($comp, $node, :$want, :$cps) {
        #TODO CPS

        my @args := nqp::clone($node.list);

        my $invocant := $comp.as_js(@args.shift, :want($T_OBJ));

        my @setup := [$invocant];

        my $method;
        if $node.name {
            if $comp.is_valid_js_identifier($node.name) {
                $method := '.' ~ $node.name;
            }
            else {
                $method := '[' ~ quote_string($node.name) ~ ']';
            }
        }
        else {
            my $method_name := $comp.as_js(@args.shift, :want($T_STR));
            @setup.push($method_name);
            $method := "[{$method_name.expr}]";
        }

        my $compiled_args := $comp.args(@args, :invocant($invocant.expr));

        my $call;
        if nqp::islist($compiled_args) {
            $compiled_args := $comp.merge_arg_groups($compiled_args);
            $call := ".apply({$invocant.expr},";
        }
        else {
            $call := '(';
        }
        @setup.push($compiled_args);

        $comp.stored_result(
            Chunk.new($T_OBJ, "nqp.op.decont($*CTX, {$invocant.expr})" ~ $method ~ $call ~ $compiled_args.expr ~ ')' , @setup, :$node), :$want);

    });

    add_simple_op('settypefinalize', $T_VOID, [$T_OBJ, $T_INT]);

    # TODO - implement and bechmark different ways of preventing the try/catch from murdering performance 
    add_op('handle', :!inlinable, sub ($comp, $node, :$want, :$cps) {
        # TODO CPS
        my @children := nqp::clone($node.list());
        if @children == 0 {
            nqp::die("The 'handle' op requires at least one child");
        }

        # If there's exactly one child, then there's nothing protecting
        # it; just compile it and we're done.
        my $protected := @children.shift();
        unless @children {
            return $comp.as_js($protected, :$want);
        }
        

        my $outer_ctx := $*CTX;
        {
            my $*HANDLER_CTX := $comp.unique_var('ctx');
            my $unwind_marker := $*BLOCK.add_tmp;

            my $try_ret := $want == $T_VOID ?? '' !! $*BLOCK.add_tmp;

            my $handle := '';
            for @children -> $type, $handler {
                if $type eq 'CATCH' {  
                    my $catch_body := $comp.as_js($handler, :want($T_OBJ));
                    $handle := Chunk.void(
                        "$unwind_marker = \{\};\n",
                        "$*HANDLER_CTX.CATCH = function() \{\n",
                        $catch_body,
                        "return {$catch_body.expr};\n",
                        "\};\n",
                        "$*HANDLER_CTX.unwind = $unwind_marker;\n" 
                    );
                }
                elsif $type eq 'CONTROL' {
                    # STUB - we are nooping this, needs to be implemented
                }
                else {
                    return $comp.NYI("Not implemented type with handle: $type");
                }
            }

            {
                my $*CTX := $*HANDLER_CTX;
                my $body := $comp.as_js($protected, :$want);
                return Chunk.new($want, $try_ret, [
                    "var $*CTX = new nqp.Ctx($outer_ctx, $outer_ctx, $outer_ctx.callThis, $outer_ctx.codeRefAttr);\n",
                    $handle,
                    "try \{",
                    $body,
                    # HACK we need to check $body.type if we handle something like return
                    (($want == $T_VOID || $body.type == $T_VOID) ?? '' !! "$try_ret = {$body.expr};\n"),
                    "\} catch (e) \{if (e === $unwind_marker) \{",
                    ($want == $T_VOID ?? '' !! "$try_ret = $unwind_marker.ret;\n"),
                    "\} else if (e instanceof nqp.NQPException) \{\n",
                    "$*CTX.catchException(e);\n",
                    # HACK - we should catch more exceptions
                    "\} else if (e instanceof TypeError) \{\n",
                    "$*CTX.catchException(nqp.wrapException(e));\n",
                    "\} else \{\n",
                    "throw e;\n",
                    "\}\n",
                    "\}\n"
                ], :$node);
            }
        }
    });


    add_simple_op('exception', $T_OBJ, [], sub () {"$*HANDLER_CTX.exception"});
    add_simple_op('rethrow', $T_VOID, [$T_OBJ], sub ($exception) {"$*CTX.rethrow($exception)"}, :sideffects);
    add_simple_op('resume', $T_VOID, [$T_OBJ], sub ($exception) {"$*CTX.resume($exception)"}, :sideffects);
    add_simple_op('throw', $T_VOID, [$T_OBJ], :sideffects, sub ($exception) {"{$*CTX}.throw($exception)"});

    add_simple_op('setpayload', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);
    add_simple_op('getpayload', $T_OBJ, [$T_OBJ, $T_OBJ]);

    add_simple_op('setmessage', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);
    add_simple_op('getmessage', $T_STR, [$T_OBJ]);

    add_simple_op('newexception', $T_OBJ, [], :sideffects);

    add_simple_op('backtracestrings', $T_OBJ, [$T_OBJ]);

    add_simple_op('findmethod', $T_OBJ, [$T_OBJ, $T_STR], :sideffects, :decont(0));
    add_simple_op('can', $T_INT, [$T_OBJ, $T_STR], :sideffects, :decont(0));

    add_simple_op('istype', $T_INT, [$T_OBJ, $T_OBJ], :sideffects, :ctx, :decont(0, 1));

    add_simple_op('split', $T_OBJ, [$T_STR, $T_STR], sub ($separator, $string) {
        "new nqp.NQPArray({$string} == '' ? [] : {$string}.split({$separator}))"
    });

    add_simple_op('ctxlexpad', :!inlinable, $T_OBJ, [$T_OBJ]);
    add_simple_op('lexprimspec', $T_INT, [$T_OBJ, $T_STR]);
    add_simple_op('objprimspec', $T_INT, [$T_OBJ]);

    add_simple_op('ctxouter', :!inlinable, $T_OBJ, [$T_OBJ]);

    add_simple_op('loadbytecode', $T_STR, [$T_STR], :ctx, :sideffects);

    add_simple_op('elems', $T_INT, [$T_OBJ]);

    add_simple_op('islist', $T_BOOL, [$T_OBJ], sub ($obj) {"($obj instanceof nqp.NQPArray)"}, :decont(0));



    #TODO CPS
    add_op('atpos', sub ($comp, $node, :$want, :$cps) { $comp.atpos($node[0], $node[1], :$node) });

    #TODO CPS
    add_op('curlexpad', :!inlinable, sub ($comp, $node, :$want, :$cps) {
            my @get;
            my @set;
            for $*BLOCK.variables -> $var {
                my $storage := $comp.is_dynamic_var($*BLOCK, $var) 
                    ?? "{$*CTX}[{quote_string($var.name)}]"
                    !! $*BLOCK.mangle_var($var);

                @set.push(quote_string($var.name) ~ 
                   ~ ': function(value) {' 
                   ~ $storage ~ ' = value' 
                   ~ '}');
                @get.push(quote_string($var.name) ~ 
                   ~ ': function() {' 
                   ~ 'return ' ~ $storage ~ ''
                   ~ '}');
            }
            Chunk.new($T_OBJ, "new nqp.CurLexpad(\{{nqp::join(',', @get)}\}, \{{nqp::join(',', @set)}\})", [], :$node);
    });

    add_op('getlexouter', :!inlinable, sub ($comp, $node, :$want, :$cps) {
        unless nqp::istype($node[0], QAST::SVal) {
            $comp.NYI("getlexouter with an argument that isn't a string literal");
        }
        my $var_name := $node[0].value;
        my $block := $*BLOCK.outer;
        while $block {
            last if $block.has_own_variable($var_name);
            $block := $block.outer;
        }

        # TODO type 

        if $comp.is_dynamic_var($block, QAST::Var.new(:name($var_name), :scope<lexical>)) {
            Chunk.new($T_OBJ, $block.ctx ~ "[" ~ quote_string($var_name) ~ "]", [], :$node);
        }
        else {
            Chunk.new($T_OBJ, $*BLOCK.outer.mangle_lexical($var_name) , [], :$node);
        }
    });

    add_simple_op('splice', $T_OBJ, [$T_OBJ, $T_OBJ, $T_INT, $T_INT], :sideffects);

    add_simple_op('setelems', $T_OBJ, [$T_OBJ, $T_INT], :sideffects);


    add_simple_op('iterator', $T_OBJ, [$T_OBJ], :sideffects);

    add_simple_op('iterval', $T_OBJ, [$T_OBJ], sub ($iter) {"$iter.iterval()"});
    add_simple_op('iterkey_s', $T_STR, [$T_OBJ], sub ($iter) {"$iter.iterkey_s()"});

    add_simple_op('existskey', $T_BOOL, [$T_OBJ, $T_STR], sub ($hash, $key) {"$hash.\$\$existskey($key)"});
    add_simple_op('deletekey', $T_OBJ, [$T_OBJ, $T_STR], sub ($hash, $key) {"$hash.\$\$deletekey($key)"}, :sideffects);

    add_simple_op('existspos', $T_BOOL, [$T_OBJ, $T_INT]);

    for <ceil floor abs log sqrt exp sin acos cos atan tan asin sinh cosh tanh> -> $func {
        add_simple_op($func ~ '_n', $T_NUM, [$T_NUM], sub ($arg) {"Math.$func($arg)"});
    }

    add_simple_op('atan2_n', $T_NUM, [$T_NUM, $T_NUM], sub ($y, $x) {"Math.atan2($y, $x)"});

    add_simple_op('sec_n', $T_NUM, [$T_NUM]);
    add_simple_op('asec_n', $T_NUM, [$T_NUM]);
    add_simple_op('sech_n', $T_NUM, [$T_NUM]);

    add_simple_op('abs_i', $T_INT, [$T_INT], sub ($arg) {"Math.abs($arg)"});
    add_simple_op('pow_n', $T_NUM, [$T_NUM, $T_NUM], sub ($base, $exponent) {"Math.pow($base, $exponent)"});

    add_simple_op('srand', $T_INT, [$T_INT], :sideffects);
    add_simple_op('rand_n', $T_NUM, [$T_NUM]);

    add_simple_op('radix', $T_OBJ, [$T_INT, $T_STR, $T_INT, $T_INT]);

    add_simple_op('stat', $T_INT, [$T_STR, $T_INT]);
    add_simple_op('stat_time', $T_NUM, [$T_STR, $T_INT]);

    add_simple_op('lstat', $T_INT, [$T_STR, $T_INT]);
    add_simple_op('lstat_time', $T_NUM, [$T_STR, $T_INT]);

    add_simple_op('defined', $T_INT, [$T_OBJ], :decont(0));
    %ops<isconcrete> := %ops<defined>;

    # TODO - those are stubs until we have repossession support
    add_simple_op('scwbenable', $T_VOID, [], -> {''});
    add_simple_op('scwbdisable', $T_VOID, [], -> {''});
    add_simple_op('neverrepossess', $T_OBJ, [$T_OBJ]);

    add_simple_op('settypehllrole', $T_OBJ, [$T_OBJ, $T_INT], :sideffects);
    add_simple_op('settypehll', $T_OBJ, [$T_OBJ, $T_STR], :sideffects);

    add_simple_op('sethllconfig', $T_OBJ,  [$T_STR, $T_OBJ], :sideffects);

    add_simple_op('bindcurhllsym', $T_OBJ, [$T_STR, $T_OBJ], :sideffects, sub ($sym, $value) {
        "nqp.op.bindhllsym({quote_string($*HLL)}, $sym, $value)"
    });
    add_simple_op('getcurhllsym', $T_OBJ, [$T_STR], sub ($sym) {
        "nqp.op.gethllsym({quote_string($*HLL)}, $sym)"
    });

    add_simple_op('bindhllsym', $T_OBJ, [$T_STR, $T_STR, $T_OBJ], :sideffects);
    add_simple_op('gethllsym', $T_OBJ, [$T_STR, $T_STR]);

    add_simple_op('hllizefor', $T_OBJ, [$T_OBJ, $T_STR], :ctx, :sideffects);

    add_simple_op('hllize', $T_OBJ, [$T_OBJ], :ctx, :sideffects, sub ($ctx, $obj) {
        "nqp.op.hllizefor($ctx, $obj, {quote_string($*HLL)})"
    });

    add_simple_op('bindcomp', $T_OBJ, [$T_STR, $T_OBJ], :sideffects);
    add_simple_op('getcomp', $T_OBJ, [$T_STR], :sideffects);

    add_simple_op('setparameterizer', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects, :ctx, :decont(0,1));
    add_simple_op('parameterizetype', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects, :ctx, :decont(0,1));
    add_simple_op('typeparameterized', $T_OBJ, [$T_OBJ], :decont(0));
    add_simple_op('typeparameters', $T_OBJ, [$T_OBJ], :ctx, :decont(0));
    add_simple_op('typeparameterat', $T_OBJ, [$T_OBJ, $T_INT], :ctx, :decont(0));

    # TODO avoid copy & paste - move it into code shared between backends
    add_op('defor', sub ($comp, $node, :$want, :$cps) {
        # TODO CPS
        if +$node.list != 2 {
            nqp::die("Operation 'defor' needs 2 operands");
        }
        my $tmp := $node.unique('defined');
        $comp.as_js(QAST::Stmts.new(
            QAST::Op.new(
                :op('bind'),
                QAST::Var.new( :name($tmp), :scope('local'), :decl('var') ),
                $node[0]
            ),
            QAST::Op.new(
                :op('if'),
                QAST::Op.new(
                    :op('defined'),
                    QAST::Var.new( :name($tmp), :scope('local') )
                ),
                QAST::Var.new( :name($tmp), :scope('local') ),
                $node[1]
            )), :$want)
    });

    add_op('ifnull', sub ($comp, $node, :$want, :$cps) {
        # TODO CPS
        if +$node.list != 2 {
            nqp::die("Operation 'ifnull' needs 2 operands");
        }

        my $result := $*BLOCK.add_tmp();
        my $expr := $comp.as_js($node[0], :want($T_OBJ));
        my $then := $comp.as_js($node[1], :want($T_OBJ));
        Chunk.new($T_OBJ, $result, [
            $expr,
            "$result = {$expr.expr};\n",
            "if ($result === null) \{\n",
            $then,
            "$result = {$then.expr};\n",
            "\}\n"], :node($node));
    });


    for <if unless> -> $op_name {
        add_op($op_name, sub ($comp, $node, :$want, :$cps) {
            #TODO CPS
            unless nqp::defined($want) {
                nqp::die("Unknown want");
            }

            my $operands := +$node.list;
            nqp::die("Operation '"~$node.op~"' needs either 2 or 3 operands")
                if $operands < 2 || $operands > 3;

            my sub needs_cond_passed($n) {
                nqp::istype($n, QAST::Block) && $n.arity > 0 &&
                    ($n.blocktype eq 'immediate' || $n.blocktype eq 'immediate_static')
            }


            my $cond_type := (needs_cond_passed($node[1]) || needs_cond_passed($node[2]))
                ?? $T_OBJ
                !! (($operands == 3 || $want == $T_VOID) ?? $T_BOOL !! $want);

            # The 2 operand form of if in a non-void context also uses the cond as the return value
            my $cond := $comp.as_js($node[0], :want($cond_type), :$cps);
            my $then;
            my $else;

            my $result;

            if $want != $T_VOID {
                $result := $*BLOCK.add_tmp();
            }

            my $boolifed_cond := $comp.coerce($cond, $T_BOOL);

            my $cond_without_sideeffects := Chunk.new($cond.type, $cond.expr, []);


            my sub compile_block($node) {
                if needs_cond_passed($node) {
                    my $block := try $*BLOCK;
                    my $loop := try $*LOOP;
                    $comp.compile_block($node, $block, $loop, :$want, :extra_args([$cond_without_sideeffects]));
                }
                else {
                    $comp.as_js($node, :$want, :$cps);
                }
            }

            if $node.op eq 'if' {
                $then := compile_block($node[1]);

                if $operands == 3 {
                    $else := compile_block($node[2]);
                }
                else {
                    $else := $comp.coerce($cond_without_sideeffects, $want);
                }
            }
            else {
                if $operands == 3 {
                    $then := compile_block($node[2]);
                }
                else {
                    $then := $comp.coerce($cond_without_sideeffects, $want);
                }
                $else := compile_block($node[1]);
            }


            # TODO ->

            if nqp::istype($cond, ChunkCPS) || nqp::istype($then, ChunkCPS) || nqp::istype($else, ChunkCPS) {
                if needs_cond_passed($then) || needs_cond_passed($else) {
                    return $comp.NYI("if ... -> \{...\} in CPS mode");
                }

                if nqp::istype($cond, ChunkCPS) {
                    return $comp.NYI("if in CPS mode with CPSish condition");
                }
                else {
                    my $cont := $comp.unique_var('cont');
                    my $result := $comp.unique_var('result');
                    return ChunkCPS.new($want, $result, [
                        $boolifed_cond,
                        "if ({$boolifed_cond.expr}) \{\n",
                        nqp::istype($then, ChunkCPS) ?? $*BLOCK.set_cont($then, $cont) !! "",
                        $then,
                        nqp::istype($then, ChunkCPS) ?? "" !! "return $cont({$then.expr});\n",
                        "\} else \{\n",
                        nqp::istype($else, ChunkCPS) ?? $*BLOCK.set_cont($else, $cont) !! "",
                        $else,
                        nqp::istype($else, ChunkCPS) ?? "" !! "return $cont({$else.expr});\n",
                        "\}\n"
                    ], $cont, :$node);
                }
            }

            Chunk.new($want, $result, [
                $boolifed_cond,
                "if ({$boolifed_cond.expr}) \{\n",
                $then,
                $want != $T_VOID ?? "$result = {$then.expr};\n" !! '',
                "\} else \{\n",
                $else,
                $want != $T_VOID ?? "$result = {$else.expr};\n" !! '',
                "\}\n"
            ], :node($node));
        });
    }

    add_op('for', sub ($comp, $node, :$want, :$cps) {
        #TODO CPS
        # TODO redo etc.

        my $handler := 1;
        my @operands;
        my $label;
        for $node.list {
            if $_.named eq 'nohandler' { $handler := 0; }
            elsif $_.named eq 'label' { $label := $_; }
            else { @operands.push($_) }
        }
        
        if +@operands != 2 {
            nqp::die("Operation 'for' needs 2 operands");
        }
        unless nqp::istype(@operands[1], QAST::Block) {
            nqp::die("Operation 'for' expects a block as its second operand");
        }
        
        unless @operands[1].blocktype eq 'immediate' {
            nqp::die("Operation 'for' expects the block to have blocktype to be immediate, is: {@operands[1].blocktype}");
        }

        my $iterator := $*BLOCK.add_tmp();

        my $list := $comp.as_js(@operands[0], :want($T_OBJ), :$cps);

        if nqp::istype($list, ChunkCPS) {
            return $comp.NYI("interating over a CPS list");
        }

        # TODO think if creating the block once, and the calling it multiple times would be faster

        my @body_args;
        my $arity := @operands[1].arity || 1;
        while $arity > 0 {
            my $iterval := $*BLOCK.add_tmp();
            @body_args.push(Chunk.new($T_OBJ, $iterval, ["$iterval = $iterator.\$\$shift();\n"]));
            $arity := $arity - 1;
        }

        my $outer     := try $*BLOCK;
        my $outer_loop := try $*LOOP;

        my $loop := LoopInfo.new($outer_loop, :$label);

        my $body := $comp.compile_block(@operands[1], $outer, $loop , :want($T_VOID), :extra_args(@body_args), :$cps);


        if nqp::istype($body, ChunkCPS) {
            # TODO handle_control
            my $cont := $comp.unique_var('cont');
            my $result := $comp.unique_var('result');
            my $loop := $comp.unique_var('cont');

            ChunkCPS.new($T_OBJ, $result, [
                $list,
                "$iterator = nqp.op.iterator({$list.expr});\n",
                "var $loop = function() \{\n",
                "if ($iterator.idx < $iterator.target) \{\n",
                $*BLOCK.set_cont($body, $loop),
                $body,
                "\} else \{\n",
                "return $cont(null);\n",
                "\}\n",
                "\}\n",
                "return $loop;"
            ], $cont);
        }
        else {
            Chunk.new($T_OBJ, 'null', [
                $list,
                "$iterator = nqp.op.iterator({$list.expr});\n",
                "while ($iterator.idx < $iterator.target) \{\n",
                $comp.handle_control($loop, $body),
                "\}\n"
            ], :node($node));
        }

    });

    for <while until repeat_while repeat_until> -> $op {
        add_op($op, sub ($comp, $node, :$want, :$cps) {
            #TODO CPS
            my $label;
            my $handler := 1;
            my @operands;
            for $node.list {
                if $_.named eq 'nohandler' { $handler := 0; }
                elsif $_.named eq 'label' { $label := $_; }
                else { @operands.push($_) }
            }

            return $comp.NYI("3 argument $op") if +@operands == 3;
            # TODO - return value
            # TODO while ... -> $cond {} 

            my $loop := LoopInfo.new($*LOOP, :$label);

            my $cond;
            my $body;
            {
                my $*LOOP := $loop;
                $cond := $comp.as_js(@operands[0], :want($T_BOOL));
                $body := $comp.as_js(@operands[1], :want($T_VOID));
            }

            if $op eq 'while' || $op eq 'until' {
                my $neg := $op eq 'while' ?? '!' !! '';

                # handle_control can set redo so we call it here
                my $handled := $comp.handle_control($loop, $body);
                Chunk.void(
                    "for (;;) \{\n",
                    ($loop.has_redo
                        ?? "if ({$loop.redo}) \{;\n"
                            ~ "{$loop.redo} = false;\n"
                            ~  "\} else \{\n"
                        !! ''), 
                    $cond,
                    "if ($neg {$cond.expr}) \{break;\}\n",
                    ($loop.has_redo ?? "\}\n" !! ''),
                    $handled,
                    "\}"
                );
            }
            else {
                # TODO redo
                my $neg := $op eq 'repeat_while' ?? '' !! '!';
                Chunk.void(
                    "do \{\n",
                    $body,
                    $cond,
                    "\} while ($neg {$cond.expr});"
                );
            }
        });
    }

    # Constant mapping.

    add_op('const', sub ($comp, $node, :$want, :$cps) {
        if nqp::existskey(%const_map, $node.name) {
            $comp.as_js(QAST::IVal.new( :value(%const_map{$node.name})), :$want, :$cps);
        }
        else {
            $comp.NYI("Constant "~$node.name);
        }
    });


    add_simple_op('findcclass', $T_INT, [$T_INT, $T_STR, $T_INT, $T_INT]);
    add_simple_op('findnotcclass', $T_INT, [$T_INT, $T_STR, $T_INT, $T_INT]);
    add_simple_op('iscclass', $T_INT, [$T_INT, $T_STR, $T_INT]);

    # Simple payload handler.
    add_op('handlepayload', :!inlinable, sub ($comp, $node, :$want, :$cps) {
        if +$node.list != 3 {
            nqp::die("The 'handlepayload' op requires three children");
        }
        my str $type := $node[1];


        my $result := $*BLOCK.add_tmp;
        if $type ne 'RETURN' {
            $comp.NYI("handlepayload with type '$type'");
        }

        my $*RETURN;

        my @toplevels := $*BLOCK.qast.list;

        my $is_last_toplevel := +@toplevels && nqp::eqaddr(@toplevels[+@toplevels - 1], $node);

        my $just_return_payload := $node[2] ~~ QAST::Op && $node[2].op eq 'lastexpayload';

        if $is_last_toplevel && $just_return_payload {
           $*RETURN := TopLevelInBlock.new(block => $*BLOCK);
        }
        else {
           $*RETURN := NotTopLevel.new();
        }

        my $protected := $comp.as_js(:want($T_OBJ), $node[0]);

        if $*RETURN.is_used {
            my $handle_result := $comp.as_js(:want($T_OBJ), $node[2]);

            Chunk.new($T_OBJ, $result, [
                "try \{\n",
                    $protected,
                    "$result = {$protected.expr};\n",
                "\} catch (\$\$e) \{\n",
                    "if (\$\$e instanceof nqp.ControlReturn) \{\n",
                        $handle_result,
                        "$result = {$handle_result.expr};\n",
                    "\} else \{",
                        "throw \$\$e;\n",
                    "\}",
                "\}"
            ]);
        }
        else {
            $protected;
        }

    });

    add_op('throwpayloadlex', :!inlinable, sub ($comp, $node, :$want, :$cps) {
        my $category := $node[0];
        my $payload := $comp.as_js(:want($T_OBJ), $node[1]);

        unless $category ~~ QAST::IVal && $category.value == nqp::const::CONTROL_RETURN {
            return $comp.NYI("throwpayloadlex with something else then a CONTROL_RETURN literal");
        }

        if $*RETURN.as_return {
            return Chunk.new($T_VOID, "", [
                $payload,
                "return {$payload.expr};\n"
            ]);
        }
        else {
            $*RETURN.mark_used();
        }

        Chunk.new($T_VOID, "", [
            $payload,
            "throw new nqp.ControlReturn({$payload.expr});\n"
        ]);
    });

    add_simple_op('lastexpayload', $T_OBJ, [], sub () { '$$e.payload' }, :!inlinable, :sideffects);


    add_op('control', sub ($comp, $node, :$want, :$cps) {
        #TODO CPS
        $comp.throw_control_exception($node.name, $*LOOP, $node[0]);
    });

    add_simple_op('create', $T_OBJ, [$T_OBJ], :sideffects);

    add_simple_op('die', $T_VOID, [$T_STR], :sideffects, sub ($msg) {"{$*CTX}.die($msg)"});
    %ops<die_s> := %ops<die>;


    add_simple_op('how', $T_OBJ, [$T_OBJ], sub ($obj) {"$obj._STable.HOW"}, :decont(0));
    add_simple_op('who', $T_OBJ, [$T_OBJ], sub ($obj) {"$obj._STable.WHO"}, :decont(0));
    add_simple_op('setwho', $T_OBJ, [$T_OBJ, $T_OBJ], sub ($obj, $who) {"($obj._STable.WHO = $who, $obj)"}, :sideffects, :decont(0));

    # TODO decont second argument
    add_simple_op('rebless', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects, :decont(0, 1));
    add_simple_op('composetype', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);

    add_simple_op('where', $T_INT, [$T_OBJ], :decont(0));
    add_simple_op('objectid', $T_INT, [$T_OBJ], :decont(0));

    # Set of sequential statements

    add_op('stmts', sub ($comp, $node, :$want, :$cps) {
        $comp.as_js(:$want, :$cps, QAST::Stmts.new( |@($node)));
    });

    # HACK
    # TODO think what we should return on 1.WHAT and "foo".WHAT
    add_simple_op('what', $T_OBJ, [$T_OBJ], sub ($obj) {"($obj._STable ? $obj._STable.WHAT : null)"}, :decont(0));

    add_simple_op('knowhowattr', $T_OBJ, [], sub () {"nqp.knowhowattr"});
    add_simple_op('knowhow', $T_OBJ, [], sub () {"nqp.knowhow"});

    add_simple_op('atkey', $T_OBJ, [$T_OBJ, $T_STR], sub ($hash, $key) {"$hash.\$\$atkey($key)"});

    for <savecapture usecapture> -> $op {
        add_simple_op($op, :!inlinable, $T_OBJ, [], sub () {
            "nqp.op.savecapture(Array.prototype.slice.call(arguments))"
        } , :sideffects);
    }

    add_simple_op('getlexdyn', $T_OBJ, [$T_STR], sub ($name) {"{$*CTX}.lookupDynamicFromCaller($name)"});
    add_simple_op('getlexcaller', $T_OBJ, [$T_STR], sub ($name) {"{$*CTX}.lookupFromSomeCaller($name)"});
    add_simple_op('getlexrel', $T_OBJ, [$T_OBJ, $T_STR]);

    add_simple_op('captureexistsnamed', $T_INT, [$T_OBJ, $T_STR]);
    add_simple_op('capturehasnameds', $T_INT, [$T_OBJ]);
    add_simple_op('captureposelems', $T_INT, [$T_OBJ]);
    add_simple_op('captureposarg', $T_OBJ, [$T_OBJ, $T_INT]);
    add_simple_op('capturenamedshash', $T_OBJ, [$T_OBJ]);

    add_simple_op('captureposprimspec', $T_OBJ, [$T_OBJ, $T_INT]);

    add_simple_op('invokewithcapture', $T_OBJ, [$T_OBJ, $T_OBJ], sub ($invokee, $capture) {
        "$invokee.\$\$apply([{$*CTX}].concat($capture.named, $capture.pos))"
    }, :sideffects);


    add_simple_op('multicachefind', $T_OBJ, [$T_OBJ, $T_OBJ]);
    add_simple_op('multicacheadd', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);

    add_simple_op('settypecache', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);
    add_simple_op('setmethcache', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects, :decont(0));
    add_simple_op('setmethcacheauth', $T_OBJ, [$T_OBJ, $T_INT], :sideffects, :decont(0));

    add_simple_op('getcodename', $T_OBJ, [$T_OBJ]);
    add_simple_op('setcodename', $T_OBJ, [$T_OBJ, $T_STR], :sideffects);

    add_simple_op('getcodeobj', $T_OBJ, [$T_OBJ]);
    add_simple_op('setcodeobj', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects);

    add_simple_op('getcodecuid', $T_STR, [$T_OBJ]);

    add_simple_op('box_i', $T_OBJ, [$T_INT, $T_OBJ]);
    add_simple_op('unbox_i', $T_INT, [$T_OBJ]);

    add_simple_op('box_n', $T_OBJ, [$T_NUM, $T_OBJ]);
    add_simple_op('unbox_n', $T_NUM, [$T_OBJ]);

    add_simple_op('box_s', $T_OBJ, [$T_STR, $T_OBJ]);
    add_simple_op('unbox_s', $T_STR, [$T_OBJ]);

    add_simple_op('setdebugtypename', $T_OBJ, [$T_OBJ, $T_STR], :sideffects);

    add_simple_op('iseq_I', $T_INT, [$T_OBJ, $T_OBJ]);
    add_simple_op('isne_I', $T_INT, [$T_OBJ, $T_OBJ]);


    # bigint arithmetic operators operators

    add_simple_op('mul_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('add_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('sub_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('div_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('pow_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('mod_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('neg_I', $T_OBJ, [$T_OBJ, $T_OBJ]);

    # bigint binary operators

    add_simple_op('bitor_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('bitxor_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('bitand_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('bitneg_I', $T_OBJ, [$T_OBJ, $T_OBJ]);
    add_simple_op('bitshiftl_I', $T_OBJ, [$T_OBJ, $T_INT, $T_OBJ]);
    add_simple_op('bitshiftr_I', $T_OBJ, [$T_OBJ, $T_INT, $T_OBJ]);

    add_simple_op('fromstr_I', $T_OBJ, [$T_STR, $T_OBJ]);
    add_simple_op('tostr_I', $T_STR, [$T_OBJ]);

    add_simple_op('base_I', $T_STR, [$T_OBJ, $T_INT]);


    add_simple_op('div_In', $T_NUM, [$T_OBJ, $T_OBJ]);
    add_simple_op('isle_I', $T_INT, [$T_OBJ, $T_OBJ]);
    add_simple_op('islt_I', $T_INT, [$T_OBJ, $T_OBJ]);
    add_simple_op('isge_I', $T_INT, [$T_OBJ, $T_OBJ]);
    add_simple_op('isgt_I', $T_INT, [$T_OBJ, $T_OBJ]);
    add_simple_op('cmp_I', $T_INT, [$T_OBJ, $T_OBJ]);

    add_simple_op('gcd_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('lcm_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('isprime_I', $T_INT, [$T_OBJ, $T_INT]);
    add_simple_op('abs_I', $T_OBJ, [$T_OBJ, $T_OBJ]);

    add_simple_op('rand_I', $T_OBJ, [$T_OBJ, $T_OBJ]);
    add_simple_op('expmod_I', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ, $T_OBJ]);
    add_simple_op('bool_I', $T_INT, [$T_OBJ]);
    add_simple_op('isbig_I', $T_INT, [$T_OBJ]);

    add_simple_op('tonum_I', $T_NUM, [$T_OBJ]);
    add_simple_op('fromnum_I', $T_OBJ, [$T_NUM, $T_OBJ]);

    add_simple_op('radix_I', $T_OBJ, [$T_INT, $T_STR, $T_INT, $T_INT, $T_OBJ]);

    add_simple_op('curcode', :!inlinable, $T_OBJ, [], sub () {"$*CTX.codeRef()"});
    add_simple_op('callercode', :!inlinable, $T_OBJ, [], sub () {"caller_ctx.codeRef()"});

    # Native Call
    add_simple_op('buildnativecall',  $T_INT, [$T_OBJ, $T_STR, $T_STR, $T_STR, $T_OBJ, $T_OBJ], :sideffects, :ctx);
    add_simple_op('nativecall', $T_OBJ, [$T_OBJ, $T_OBJ, $T_OBJ], :sideffects);

    add_simple_op('initnativecall', $T_INT, [], :sideffects);

    # Continuations
    add_simple_op('continuationreset', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects, :ctx);
    add_simple_op('continuationinvoke', $T_OBJ, [$T_OBJ, $T_OBJ], :sideffects, :ctx, :cps_aware);

    add_simple_op('continuationcontrol', $T_OBJ, [$T_INT, $T_OBJ, $T_OBJ], :ctx, :required_cps);

    # Dealing with compiled compunits

    add_simple_op('iscompunit', $T_INT, [$T_OBJ]);
    add_simple_op('compunitcodes', $T_OBJ, [$T_OBJ]);
    add_simple_op('compunitmainline', $T_OBJ, [$T_OBJ]);

    method compile_op($comp, $op, :$want, :$cps) {
        my str $name := $op.op;
        if nqp::existskey(%ops, $name) {
            %ops{$name}($comp, $op, :$want, :$cps);
        }
        else {
            $comp.NYI("unimplemented QAST::Op {$op.op}");
        }
    }

    add_op('takedispatcher', sub ($comp, $node, :$want, :$cps) {
        if +@($node) != 1 || !nqp::istype($node[0], QAST::SVal) {
            nqp::die('takedispatcher requires one string literal operand');
        }
        my $var := $node[0].value;

        my $set_var := $comp.is_dynamic_var($*BLOCK, QAST::Var.new(:name($var), :scope<lexical>))
            ?? "{$*CTX}.bind({quote_string($var)}, nqp.currentDispatcher);\n" 
            !! $*BLOCK.mangle_lexical($var) ~ " = nqp.currentDispatcher;\n";

        Chunk.void(
            "if (nqp.currentDispatcher !== undefined) \{"
            ~ $set_var
            ~ "nqp.currentDispatcher = undefined;\n"
            ~ "\}\n"
        );
    });
    add_simple_op('cleardispatcher', $T_VOID, [], sub () {"nqp.currentDispatcher = undefined"}, :sideffects);
    add_simple_op('setdispatcher', $T_VOID, [$T_OBJ], sub ($value) {"nqp.currentDispatcher = $value"}, :sideffects);
    add_simple_op('ctxcaller', $T_OBJ, [$T_OBJ], :!inlinable);
    add_simple_op('ctx', $T_OBJ, [], :!inlinable, sub () {$*CTX});

    add_simple_op('lock', $T_OBJ, [$T_OBJ], sub ($lock) {$lock});
    add_simple_op('unlock', $T_OBJ, [$T_OBJ], sub ($lock) {$lock});

    add_simple_op('sleep', $T_NUM, [$T_NUM], :sideffects);
}

