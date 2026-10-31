// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArcfloatTestBase} from "./Arcfloat.Base.t.sol";
import {Arcfloat} from "../Arcfloat.sol";

/// forge-config: default.fuzz.runs = 512
contract ArcfloatFuzzTest is ArcfloatTestBase {
    function testFuzz_QuoteAdvance(uint256 face, uint16 bps) public view {
        face = bound(face, 1e6, type(uint128).max);
        bps = uint16(bound(bps, 50, 2000));
        uint256 adv = af.quoteAdvance(face, bps);
        assertEq(adv, face * (10_000 - bps) / 10_000);
        assertLt(adv, face);
        // discount is at least face*bps/10000 (rounding down the advance never favours the freelancer)
        assertGe(face - adv, face * bps / 10_000);
    }

    function testFuzz_QuoteAdvance_InvalidInputsRevert(uint256 face, uint16 bps) public {
        vm.assume(face < 1e6 || face > type(uint128).max || bps < 50 || bps > 2000);
        if (face < 1e6 || face > type(uint128).max) {
            vm.expectRevert(Arcfloat.InvalidFaceAmount.selector);
        } else {
            vm.expectRevert(Arcfloat.InvalidDiscountBps.selector);
        }
        af.quoteAdvance(face, bps);
    }

    function testFuzz_OverFundingCapsAtRemaining(uint256 first, uint256 second) public {
        uint256 id = _createStd();
        first = bound(first, 10_000, TARGET - 10_000);
        second = bound(second, 1, 10_000e6);
        _fund(id, funders[0], first);
        uint256 remaining = TARGET - first;
        if (second < remaining && second < 10_000) {
            vm.prank(funders[1]);
            vm.expectRevert(Arcfloat.ContributionTooSmall.selector);
            af.fund(id, second);
            return;
        }
        uint256 before = _bal(funders[1]);
        uint256 accepted = _fund(id, funders[1], second);
        assertEq(accepted, second < remaining ? second : remaining);
        assertEq(before - _bal(funders[1]), accepted);
        assertLe(af.getInvoice(id).totalFunded, TARGET);
    }

    function _fundSplit(uint256 id, uint256 n, uint256 seed, uint256 target) internal returns (uint256[] memory c) {
        c = new uint256[](n);
        uint256 remaining = target;
        for (uint256 i; i < n; ++i) {
            if (i == n - 1) {
                c[i] = remaining;
            } else {
                uint256 maxHere = remaining - (n - 1 - i) * 10_000; // keep room for later funders
                c[i] = bound(uint256(keccak256(abi.encode(seed, i))), 10_000, maxHere);
            }
            remaining -= c[i];
            usdc.mint(funders[i], c[i]);
            _fund(id, funders[i], c[i]);
        }
    }

    function _claimAllAndCheck(uint256 id, uint256[] memory c, uint256 face, uint256 target, uint8 rot) internal {
        uint256 n = c.length;
        uint256 sumShares;
        uint256 total;
        for (uint256 k; k < n; ++k) {
            uint256 who = (k + rot) % n;
            uint256 share = face * c[who] / target;
            assertLe(share, face);
            sumShares += share;
            uint256 got = _claimRepayment(id, funders[who]);
            total += got;
            // non-last claimants get exactly their share; the last also gets all dust
            assertEq(got, k < n - 1 ? share : share + (face - sumShares));
        }
        assertLe(sumShares, face);
        assertEq(total, face);
    }

    /// Sum of pro-rata shares + dust == face; no share ever exceeds face; contract ends at 0.
    function testFuzz_ProRata_SharesPlusDustEqualFace(uint256 face, uint16 bps, uint8 nSeed, uint256 seed, uint8 rot)
        public
    {
        face = bound(face, 1e6, 1e15);
        bps = uint16(bound(bps, 50, 2000));
        uint256 target = af.quoteAdvance(face, bps);
        uint256 id = _create(face, bps);
        uint256[] memory c = _fundSplit(id, bound(nSeed, 1, 10), seed, target);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        assertEq(_bal(freelancer), target);
        _pay(id);
        assertEq(_bal(address(af)), face);
        _claimAllAndCheck(id, c, face, target, rot);
        assertEq(_bal(address(af)), 0);
        assertEq(af.outstanding(id), 0);
    }

    function testFuzz_Refund_ExactAndConserved(uint256 a, uint256 b) public {
        uint256 id = _createStd();
        a = bound(a, 10_000, 400e6);
        b = bound(b, 10_000, 400e6);
        _fund(id, funders[0], a);
        _fund(id, funders[1], b);
        vm.prank(freelancer);
        af.cancelInvoice(id);
        assertEq(af.outstanding(id), a + b);
        uint256 b0 = _bal(funders[0]);
        uint256 b1 = _bal(funders[1]);
        vm.prank(funders[0]);
        af.claimRefund(id);
        vm.prank(funders[1]);
        af.claimRefund(id);
        assertEq(_bal(funders[0]) - b0, a);
        assertEq(_bal(funders[1]) - b1, b);
        assertEq(_bal(address(af)), 0);
    }
}
