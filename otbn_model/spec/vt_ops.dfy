include "vt_types.dfy"
include "vt_consts.dfy"
include "bv_ops.dfy"
include "../lib/powers.dfy"
include "../lib/congruences.dfy"

module vt_ops {
    import opened vt_types
    import opened bv_ops
    import opened vt_consts
    import opened powers
    import opened congruences

    function eval_reg32(s: state, r: reg32_t) : uint32
    {
        s.gprs[r.index]
    }

    predicate evalIns32(xins: ins32, s: state, r: state)
    {
        if !s.ok then
            !r.ok
        else
            r.ok && (valid_state(s) ==> valid_state(r))
    }

    function eval_reg256(s: state, r: reg256_t) : uint256
    {
        match r {
            case WDR(index) => s.wdrs[r.index]
            case WMOD => s.wmod
            case WRND => s.wrnd
            case WACC => s.wacc
        }
    }

    predicate eval_ins256(wins: ins256, s: state, r: state)
    {
        if !s.ok then
            !r.ok
        else
            r.ok && (valid_state(s) ==> valid_state(r))
    }

    predicate evalBlock(block: codes, s: state, r: state)
    {
        if block.CNil? then
            r == s
        else
            exists r': state :: evalCode(block.hd, s, r') && evalBlock(block.tl, r', r)
    }

    function eval_cond(s: state, wc: whileCond): nat
    {
        match wc 
            case RegCond(r) => eval_reg32(s, r)
            case ImmCond(c) => c
    }

    predicate evalWhile(c: code, n: nat, s: state, r: state)
        decreases c, n
    {
        if s.ok then
            if n == 0 then
                s == r
            else
                exists loop_body_end: state :: evalCode(c, s, loop_body_end)
                    && evalWhile(c, n - 1, loop_body_end, r)
        else
            !r.ok
    }

    predicate evalCode(c: code, s: state, r: state)
        decreases c, 0
    {
        match c
            case Ins32(ins) => evalIns32(ins, s, r)
            case Ins256(ins) => eval_ins256(ins, s, r)
            case Block(block) => evalBlock(block, s, r)
            //case IfElse(cond, ifT, ifF) => evalIfElse(cond, ifT, ifF, s, r)
            case While(cond, body) => evalWhile(body, eval_cond(s, cond), s, r)
    }

    function select_fgroup(fgps: fgroups_t, which: uint1): flags_t
    {
        if which == 0 then fgps.fg0 else fgps.fg1
    }

    function get_flag(fgps: fgroups_t, which_group: uint1, which_flag: uint2) : bool
    {
        if which_flag == 0 then select_fgroup(fgps, which_group).cf 
        else if which_flag == 1 then select_fgroup(fgps, which_group).msb
        else if which_flag == 2 then select_fgroup(fgps, which_group).lsb
        else select_fgroup(fgps, which_group).zero
    }

    function get_cf0(fgps: fgroups_t): bool
    {
        select_fgroup(fgps, 0).cf 
    }

    function get_cf1(fgps: fgroups_t): bool
    {
        select_fgroup(fgps, 1).cf 
    }

    function update_fgroups(fgps: fgroups_t, which_group: uint1, new_flags_t: flags_t) : fgroups_t
    {
        if which_group == 0 then fgps.(fg0 := new_flags_t) else fgps.(fg1 := new_flags_t)
    }

    function otbn_addc(x: uint256, y: uint256, shift: shift_t, carry: bool) : (uint256, flags_t)
    {
        var cin := if carry then 1 else 0;
        var (sum, cout) := uint256_addc(x, uint256_sb(y, shift), cin);
        // TODO: MSB/LSB
        var fg := flags_t(cout == 1, false, false, sum == 0);
        (sum, fg)
    }

    // function otbn_addm(x: uint256, y: uint256, mod: uint256) : uint256
    // {
    //     var (sum, _) := otbn_add_carray(x, y, false);
    //     if sum >= mod then sum - mod else sum
    // }

    function otbn_subb(x: uint256, y: uint256, shift: shift_t, borrow: bool) : (uint256, flags_t)
    {
        var cf := if borrow then 1 else 0;
        var (diff, cout) := uint256_subb(x, uint256_sb(y, shift), cf);
        // TODO: MSB/LSB
        var fg := flags_t(cout == 1, false, false, diff == 0);
        (diff, fg)
    }

    // function otbn_subm(x: uint256, y: uint256, wmod: uint256) : uint256
    //     requires false;
    // {
    //     // FIXME: some bound checking?
    //     assume false;
    //     var result := (x as bv256 - y as bv256) as uint256;
    //     if result >= wmod then (result as bv256 - wmod as bv256) as uint256 else result
    // }

    function otbn_mulqacc(
        zero: bool,
        x: uint256, qx: uint2,
        y: uint256, qy: uint2,
        shift: uint2,
        acc: uint256) : uint256
    {
        var product := uint256_qmul(x, qx, y, qy);
        var shift := uint256_sb(product, SFT(true, shift * 8));
        if zero then shift else (acc + shift) % BASE_256
    }

    predicate otbn_mulqacc_is_safe(shift: uint2, acc: uint256)
    {
        // make sure no overflow from shift (product is assumed to be 128 bits)
        && (shift <= 2) 
        // make sure no overflow from addtion
        && (acc + otbn_qshift_safe(BASE_128 - 1, shift) < BASE_256)
    }

    // mulquacc but no overflow
    function otbn_mulqacc_safe(
        zero: bool,
        x: uint256, qx: uint2,
        y: uint256, qy: uint2,
        shift: uint2,
        acc: uint256) : uint256

        requires otbn_mulqacc_is_safe(shift, acc);
    {
        var product := uint256_qmul(x, qx, y, qy);
        var shift := otbn_qshift_safe(product, shift);
        if zero then shift else acc + shift
    }

    // quater shift but no overflow
    function otbn_qshift_safe(x: uint256, q: uint2): (r: uint256)
        requires (q == 1) ==> (x < BASE_192);
        requires (q == 2) ==> (x < BASE_128);
        requires (q == 3) ==> (x < BASE_64);
    {
        if q == 0 then x
        else if q == 1 then x * BASE_64
        else if q == 2 then x * BASE_128
        else x * BASE_192
    }

    function otbn_xor(x: uint256, y: uint256, shift: shift_t) : uint256
    {
        uint256_xor(x, uint256_sb(y, shift))
    }

    function otbn_or(x: uint256, y: uint256, shift: shift_t) : uint256
    {
        uint256_or(x, uint256_sb(y, shift))
    }
            
    function otbn_and(x: uint256, y: uint256, shift: shift_t) : uint256
    {
        uint256_and(x, uint256_sb(y, shift))
    }

    function otbn_rshi(x: uint256, y: uint256, shift_amt: int) : uint256
        requires 0 <= shift_amt < 256;
    {
        var concat : int := x * BASE_256 + y;
        (concat / pow2(shift_amt)) % BASE_256
    }

    function {:opaque} to_nat(xs: seq<uint256>): nat
    {
        if |xs| == 0 then 0
        else
            var len' := |xs| - 1;
            to_nat(xs[..len']) + xs[len'] * pow_B256(len')
    }

    lemma to_nat_lemma1(xs: seq<uint256>)
        requires |xs| == 1
        ensures to_nat(xs) == xs[0]
    {
        reveal to_nat();
        reveal power();
    }

    lemma to_nat_lemma2(xs: seq<uint256>)
        requires |xs| == 2
        ensures to_nat(xs) == xs[0] + xs[1] * BASE_256
    {
        reveal to_nat();
        to_nat_lemma1(xs[..1]);
        reveal power();
    }

    lemma to_nat_bound_lemma(x: seq<uint256>)
        ensures to_nat(x) < pow_B256(|x|)
    {
        if |x| == 0 {
            reveal to_nat();
        } else {
            assume false;
        }
    }

    lemma to_nat_zero_prepend_lemma(xs: seq<uint256>)
        ensures to_nat([0] + xs) == to_nat(xs) * BASE_256

    lemma to_nat_prefix_lemma(xs: seq<uint256>, i: nat)
        requires 1 <= i < |xs|;
        ensures to_nat(xs[..i]) == to_nat(xs[..i-1]) + xs[i-1] * pow_B256(i-1);
    {
        assert xs[..i][..i-1] == xs[..i-1];
        reveal to_nat();
    }

    lemma uint512_view_lemma(num: uint512_view_t)
        ensures num.full
            == to_nat([num.lh, num.uh])
            == num.lh + num.uh * BASE_256;
    {
        reveal uint512_lh();
        reveal uint512_uh();
        to_nat_lemma2([num.lh, num.uh]);
    }

    lemma to_nat_zero_extend_lemma(xs': seq<uint256>, xs: seq<uint256>) 
        requires |xs'| < |xs|
        requires var len' := |xs'|;
            && xs[..len'] == xs'
            && xs[len'.. ] == seq(|xs| - len', i => 0)
        ensures to_nat(xs') == to_nat(xs);
    {
        var len, len' := |xs|, |xs'|;
        reveal to_nat();
        if len != len' + 1 {
            var len'' := len-1;
            calc == {
                to_nat(xs);
                to_nat(xs[..len'']) + xs[len''] * pow_B256(len'');
                to_nat(xs[..len'']);
                { to_nat_zero_extend_lemma(xs', xs[..len'']); }
                to_nat(xs');
            }
        }
    }

    function seq_addc(xs: seq<uint256>, ys: seq<uint256>) : (seq<uint256>, uint1)
        requires |xs| == |ys|
        ensures var (zs, cout) := seq_addc(xs, ys);
            && |zs| == |xs|
    {
        if |xs| == 0 then ([], 0)
        else 
            var len' := |xs| - 1;
            var (zs', cin) := seq_addc(xs[..len'], ys[..len']);
            var (z, cout) := uint256_addc(xs[len'], ys[len'], cin);
            (zs' + [z], cout)
    }

    lemma seq_addc_nat_lemma(xs: seq<uint256>, ys: seq<uint256>, zs: seq<uint256>, cout: uint1)
        requires |xs| == |ys|;
        requires seq_addc(xs, ys) == (zs, cout);
        ensures to_nat(xs) + to_nat(ys) == to_nat(zs) + cout * pow_B256(|xs|)
    {
        reveal to_nat();
        if |xs| == 0 {
            reveal power();
        } else {
            var len' := |xs| - 1;
            var (zs', cin) := seq_addc(xs[..len'], ys[..len']);
            var (z, _) := uint256_addc(xs[len'], ys[len'], cin);
            assert xs[len'] + ys[len'] + cin == z + cout * BASE_256;

            calc {
                to_nat(zs);
                to_nat(zs') + z * pow_B256(len');
                    { seq_addc_nat_lemma(xs[..len'], ys[..len'], zs', cin); }
                to_nat(xs[..len']) + to_nat(ys[..len']) - cin * pow_B256(len') + z * pow_B256(len');
                to_nat(xs[..len']) + to_nat(ys[..len']) + xs[len'] * pow_B256(len') + ys[len'] * pow_B256(len') - cout * BASE_256 * pow_B256(len');
                    { reveal to_nat(); }
                to_nat(xs) + to_nat(ys) - cout * BASE_256 * pow_B256(len');
                    { reveal power(); }
                to_nat(xs) + to_nat(ys) - cout * pow_B256(|xs|);
            }
            assert to_nat(zs) + cout * pow_B256(|xs|) == to_nat(xs) + to_nat(ys);
        }
    }

    function seq_subb(xs: seq<uint256>, ys: seq<uint256>) : (seq<uint256>, uint1)
        requires |xs| == |ys|
        ensures var (zs, bout) := seq_subb(xs, ys);
            && |zs| == |xs|
    {
        if |xs| == 0 then ([], 0)
        else 
            var len' := |xs| - 1;
            var (zs, bin) := seq_subb(xs[..len'], ys[..len']);
            var (z, bout) := uint256_subb(xs[len'], ys[len'], bin);
            (zs + [z], bout)
    }

    lemma seq_subb_nat_lemma(xs: seq<uint256>, ys: seq<uint256>, zs: seq<uint256>, bout: uint1)
        requires |xs| == |ys|
        requires seq_subb(xs, ys) == (zs, bout);
        ensures to_nat(xs) - to_nat(ys) + bout * pow_B256(|xs|) == to_nat(zs)
    {
        reveal to_nat();
        if |xs| == 0 {
            reveal power();
        } else {
            var len' := |xs| - 1;
            var (zs', bin) := seq_subb(xs[..len'], ys[..len']);
            var (z, _) := uint256_subb(xs[len'], ys[len'], bin);
            assert bout * BASE_256 + xs[len'] - bin - ys[len'] == z;
            
            calc {
                to_nat(zs);
                to_nat(zs') + z * pow_B256(len');
                    { seq_subb_nat_lemma(xs[..len'], ys[..len'], zs', bin); }
                to_nat(xs[..len']) - to_nat(ys[..len']) + bin * pow_B256(len') + z * pow_B256(len');
                to_nat(xs[..len']) - to_nat(ys[..len']) + xs[len'] * pow_B256(len') - ys[len'] * pow_B256(len') + bout * BASE_256 * pow_B256(len');
                    { reveal to_nat(); }
                to_nat(xs) - to_nat(ys) + bout * BASE_256 * pow_B256(len');
                    { reveal power(); }
                to_nat(xs) - to_nat(ys) + bout * pow_B256(|xs|);
            }
        }
    }

    lemma seq_subb_safe_nat_lemma(xs: seq<uint256>, ys: seq<uint256>)
        requires |xs| == |ys|
        requires to_nat(xs) >= to_nat(ys)
        ensures seq_subb(xs, ys).1 == 0
    {
        var (zs, bout) := seq_subb(xs, ys);
        seq_subb_nat_lemma(xs, ys, zs, bout);

        if bout == 1 {
            assert to_nat(xs) - to_nat(ys) + pow_B256(|xs|) == to_nat(zs);
            to_nat_bound_lemma(xs);
            to_nat_bound_lemma(ys);
            to_nat_bound_lemma(zs);
            assert false;
        }
    }

   datatype pub_key = pub_key(
        e: nat, 
        m: nat,
        m0d: uint256,
        B256_INV: nat,
        R: nat,
        RR: nat,
        R_INV: nat)

    predicate pub_key_inv(key: pub_key)
    {
        && key.m != 0
        && cong_B256(key.m0d * key.m, BASE_256-1)

        && cong(BASE_256 * key.B256_INV, 1, key.m)

        && key.R == power(BASE_256, NUM_WORDS)

        && key.RR < key.m
        && cong(key.RR, key.R * key.R, key.m)

        && key.R_INV == power(key.B256_INV, NUM_WORDS)
        && cong(key.R_INV * key.R, 1, key.m)
    }

    datatype mm_vars = mm_vars(
        x_iter: iter_t,
        y_iter: iter_t,
        m_iter: iter_t,
        rr_iter: iter_t,
        m0d_iter: iter_t,
        key: pub_key)

    predicate mm_iter_inv(iter: iter_t, wmem: wmem_t, addr: int)
    {
        addr == NA ||
        (
            && iter_inv(wmem, addr, iter)
            && iter.index == 0
            && |iter.buff| == NUM_WORDS
        )
    }

    predicate m0d_iter_inv(iter: iter_t, wmem: wmem_t, addr: int, m0d: uint256)
    {
        addr == NA ||
        (
            && iter_inv(wmem, addr, iter)
            && iter.index == 0
            && |iter.buff| == 1
            && iter.buff[0] == m0d
        )
    }

    predicate mm_vars_inv(
        vars: mm_vars,
        wmem: wmem_t,
        x_addr: int,
        y_addr: int,
        m_addr: int,
        rr_addr: int,
        m0d_addr: int)
    {
        && pub_key_inv(vars.key)

        && mm_iter_inv(vars.x_iter, wmem, x_addr)
        && mm_iter_inv(vars.y_iter, wmem, y_addr)

        && mm_iter_inv(vars.m_iter, wmem, m_addr)
        && to_nat(vars.m_iter.buff) == vars.key.m
        // && cong_B256(vars.key.m0d * vars.m_iter.buff[0], BASE_256-1) // provable

        && mm_iter_inv(vars.rr_iter, wmem, rr_addr)
        && to_nat(vars.rr_iter.buff) == vars.key.RR

        && m0d_iter_inv(vars.m0d_iter, wmem, m0d_addr, vars.key.m0d)
    }
}