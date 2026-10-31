// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArcfloatTestBase} from "./Arcfloat.Base.t.sol";
import {Arcfloat} from "../Arcfloat.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// Payment, repayment claims, dust, pay-before-funded and default marking.
contract ArcfloatPayTest is ArcfloatTestBase {
    // Hand-computed for FACE=1000e6, TARGET=950e6, contributions 500e6/300e6/150e6:
    // floor(1000e6*500e6/950e6)=526_315_789, 300e6 -> 315_789_473, 150e6 -> 157_894_736; dust=2.
    uint256 internal constant S0 = 526_315_789;
    uint256 internal constant S1 = 315_789_473;
    uint256 internal constant S2 = 157_894_736;

    // ---------------- payInvoice ----------------
    function test_Pay_FundedPathPullsFaceAndEmits() public {
        uint256 id = _fundedStd();
        uint256 cBefore = _bal(client);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoicePaid(id, client, FACE, false);
        _pay(id);

        assertEq(cBefore - _bal(client), FACE);
        assertEq(_bal(address(af)), FACE);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Paid));
        assertFalse(af.getInvoice(id).paidBeforeFunded);
        assertEq(af.getInvoice(id).repaymentPool, FACE);
        assertEq(af.outstanding(id), FACE);
    }

    function test_Pay_RevertsForNonClient() public {
        uint256 id = _fundedStd();
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.NotClient.selector);
        af.payInvoice(id);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.NotClient.selector);
        af.payInvoice(id);
    }

    function test_Pay_DoublePaymentReverts() public {
        uint256 id = _fundedStd();
        _pay(id);
        vm.prank(client);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.payInvoice(id);
        assertEq(_bal(address(af)), FACE);
    }

    function test_Pay_InsufficientAllowanceReverts() public {
        uint256 id = _fundedStd();
        vm.prank(client);
        usdc.approve(address(af), FACE - 1);
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(af), FACE - 1, FACE
            )
        );
        af.payInvoice(id);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded)); // unchanged
    }

    // ---------------- claimRepayment (pro rata) ----------------
    function test_Claim_ProRataMatchesHandComputedValues() public {
        uint256 id = _fundedStd();
        _pay(id);

        assertEq(af.claimableRepayment(id, funders[0]), S0);
        assertEq(af.claimableRepayment(id, funders[1]), S1);
        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.RepaymentClaimed(id, funders[0], S0);
        assertEq(_claimRepayment(id, funders[0]), S0);
        assertEq(_claimRepayment(id, funders[1]), S1);
        // Last claimant gets share + 2 dust.
        assertEq(af.claimableRepayment(id, funders[2]), S2 + 2);
        assertEq(_claimRepayment(id, funders[2]), S2 + 2);

        assertEq(S0 + S1 + S2 + 2, FACE);
        assertEq(_bal(address(af)), 0);
        assertEq(af.outstanding(id), 0);
        assertEq(af.claimableRepayment(id, funders[2]), 0);
    }

    function test_Claim_Dust_LastClaimantGetsRemainderInEveryOrder() public {
        // face=1_000_003, 100 bps -> target 990_002; contributions 500_000/300_001/190_001.
        // shares: 505_050 / 303_031 / 191_920 (sum 1_000_001) -> dust 2.
        uint256[3] memory share = [uint256(505_050), 303_031, 191_920];
        uint8[3][6] memory orders = [
            [uint8(0), 1, 2], [uint8(0), 2, 1], [uint8(1), 0, 2],
            [uint8(1), 2, 0], [uint8(2), 0, 1], [uint8(2), 1, 0]
        ];
        for (uint256 o; o < orders.length; ++o) {
            uint256 snap = vm.snapshotState();
            uint256 id = _create(1_000_003, 100);
            _fund(id, funders[0], 500_000);
            _fund(id, funders[1], 300_001);
            _fund(id, funders[2], 190_001);
            assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
            _pay(id);
            assertEq(_bal(address(af)), 1_000_003);

            uint256 total;
            for (uint256 k; k < 3; ++k) {
                uint8 who = orders[o][k];
                uint256 got = _claimRepayment(id, funders[who]);
                assertEq(got, k == 2 ? share[who] + 2 : share[who], "payout");
                total += got;
            }
            assertEq(total, 1_000_003);
            assertEq(_bal(address(af)), 0);
            assertEq(af.outstanding(id), 0);
            vm.revertToState(snap);
        }
    }

    function test_Claim_TwiceReverts() public {
        uint256 id = _fundedStd();
        _pay(id);
        _claimRepayment(id, funders[0]);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.AlreadyClaimed.selector);
        af.claimRepayment(id);
        // Also for the last claimant.
        _claimRepayment(id, funders[1]);
        _claimRepayment(id, funders[2]);
        vm.prank(funders[2]);
        vm.expectRevert(Arcfloat.AlreadyClaimed.selector);
        af.claimRepayment(id);
    }

    function test_Claim_NonEntitledAndWrongStatusReverts() public {
        uint256 id = _fundedStd();
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector); // not yet paid
        af.claimRepayment(id);
        _pay(id);

        vm.prank(stranger);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.claimRepayment(id);
        vm.prank(client);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.claimRepayment(id);
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.claimRepayment(id);
        // Refund path is not available on a funded-path payment.
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.claimRefund(id);
    }

    function test_ClaimFreelancer_RevertsInFundedPathAndForOthers() public {
        uint256 id = _fundedStd();
        _pay(id);
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.NothingToClaim.selector);
        af.claimFreelancer(id);
        vm.prank(stranger);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.claimFreelancer(id);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.claimFreelancer(id);
    }

    // ---------------- pay before funded ----------------
    function test_PayBeforeFunded_FreelancerGetsFaceFundersRefunded() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 300e6);
        _fund(id, funders[1], 200e6);
        assertEq(_bal(freelancer), 0);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoicePaid(id, client, FACE, true);
        _pay(id);
        assertTrue(af.getInvoice(id).paidBeforeFunded);
        assertEq(_bal(address(af)), FACE + 500e6);
        assertEq(af.outstanding(id), FACE + 500e6);

        // Funding / withdrawing after payment is closed.
        vm.prank(funders[2]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.fund(id, 10e6);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.withdrawContribution(id);
        // Repayment path is not available.
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.claimRepayment(id);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.FreelancerClaimed(id, freelancer, FACE);
        vm.prank(freelancer);
        af.claimFreelancer(id);
        assertEq(_bal(freelancer), FACE);

        uint256 b0 = _bal(funders[0]);
        vm.prank(funders[0]);
        af.claimRefund(id);
        vm.prank(funders[1]);
        af.claimRefund(id);
        assertEq(_bal(funders[0]), b0 + 300e6);
        assertEq(_bal(address(af)), 0);
        assertEq(af.outstanding(id), 0);

        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.NothingToClaim.selector);
        af.claimFreelancer(id);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.AlreadyClaimed.selector);
        af.claimRefund(id);
        vm.prank(stranger);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.claimRefund(id);
    }

    function test_PayBeforeFunded_WithNoFundersOnlyFreelancerClaims() public {
        uint256 id = _createStd();
        _pay(id);
        assertEq(_bal(address(af)), FACE);
        vm.prank(freelancer);
        af.claimFreelancer(id);
        assertEq(_bal(freelancer), FACE);
        assertEq(_bal(address(af)), 0);
    }

    // ---------------- markDefaulted ----------------
    function test_Default_NotBeforeOrAtDueDate() public {
        uint256 id = _fundedStd();
        uint64 due = af.getInvoice(id).dueDate;
        vm.expectRevert(Arcfloat.NotOverdue.selector);
        af.markDefaulted(id);
        vm.warp(due); // exactly due: still not overdue
        vm.expectRevert(Arcfloat.NotOverdue.selector);
        af.markDefaulted(id);
    }

    function test_Default_RevertsOnOpenPaidCancelled() public {
        uint256 open = _createStd();
        vm.warp(block.timestamp + TERM + 1);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.markDefaulted(open);

        vm.warp(1_700_000_000);
        uint256 paid = _fundedStd();
        _pay(paid);
        uint256 cancelled = _createStd();
        vm.prank(freelancer);
        af.cancelInvoice(cancelled);
        vm.warp(block.timestamp + TERM + 1);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.markDefaulted(paid);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.markDefaulted(cancelled);
    }

    function test_Default_AnyoneCanMarkAndItIsRecordOnly() public {
        uint256 id = _fundedStd();
        vm.warp(block.timestamp + TERM + 1);
        uint256 afBal = _bal(address(af));
        uint256 outBefore = af.outstanding(id);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoiceDefaulted(id, block.timestamp);
        vm.prank(stranger);
        af.markDefaulted(id);

        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Defaulted));
        assertEq(_bal(address(af)), afBal);
        assertEq(af.outstanding(id), outBefore);
        assertEq(af.contributionOf(id, funders[0]), 500e6);

        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.markDefaulted(id);
        // No refund / withdraw path for funders either.
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.claimRefund(id);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.withdrawContribution(id);
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.cancelInvoice(id);
    }

    function test_Default_LatePaymentStillRepaysFunders() public {
        uint256 id = _fundedStd();
        vm.warp(block.timestamp + TERM + 1);
        af.markDefaulted(id);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoicePaid(id, client, FACE, false);
        _pay(id);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Paid));

        assertEq(_claimRepayment(id, funders[0]), S0);
        assertEq(_claimRepayment(id, funders[1]), S1);
        assertEq(_claimRepayment(id, funders[2]), S2 + 2);
        assertEq(_bal(address(af)), 0);
    }

    function test_Fund_NotPossibleAfterDefault() public {
        uint256 id = _fundedStd();
        vm.warp(block.timestamp + TERM + 1);
        af.markDefaulted(id);
        vm.prank(funders[5]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.fund(id, 10e6);
    }
}
