include "../spec/rsa_ops.dfy"

module subb_lemmas {
    import opened bv_ops
    import opened vt_ops
    import opened rsa_ops
    import opened vt_consts
    import opened powers
    import opened congruences

    predicate subb_inv(
        dst: seq<uint256>,
        carry: uint1,
        src1: seq<uint256>,
        src2: seq<uint256>,
        index: nat)

    requires |dst| == |src1| == |src2|;
    requires index <= |src1|;
    {
        (dst[..index], carry)
            == seq_subb(src1[..index], src2[..index])
    }

    lemma subb_inv_peri_lemma(
        dst: seq<uint256>,
        new_carry: uint1,
        src1: seq<uint256>,
        src2: seq<uint256>,
        old_carry: uint1,
        index: nat)

    requires |dst| == |src1| == |src2|;
    requires index < |src1|;
    requires subb_inv(dst, old_carry, src1, src2, index);
    requires (dst[index], new_carry)
        == uint256_subb(src1[index], src2[index], old_carry);
    ensures subb_inv(dst, new_carry, src1, src2, index + 1);
    {
        var (zs, bin) := seq_subb(src1[..index], src2[..index]);
        var (z, bout) := uint256_subb(src1[index], src2[index], old_carry);

        assert dst[..index+1] == zs + [z];
        assert src1[..index+1] == src1[..index] + [src1[index]];
        assert src2[..index+1] == src2[..index] + [src2[index]];
    }

    lemma subb_inv_post_lemma(
        dst: seq<uint256>,
        carry: uint1,
        src1: seq<uint256>,
        src2: seq<uint256>)
        
    requires |dst| == |src1| == |src2|;
    requires subb_inv(dst, carry, src1, src2, |dst|);
    ensures to_nat(dst) == to_nat(src1) - to_nat(src2) + carry * pow_B256(|dst|);
    ensures carry == 0 <==> to_nat(src1) >= to_nat(src2)
    {
        var index := |dst|;
        assert dst[..index] == dst;
        assert src1[..index] == src1;
        assert src2[..index] == src2;
    
        seq_subb_nat_lemma(src1, src2, dst, carry);

        assert to_nat(src1) - to_nat(src2) + carry * pow_B256(index) == to_nat(dst);

        to_nat_bound_lemma(dst);
    }
}