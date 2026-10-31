// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArcfloatTestBase} from "./Arcfloat.Base.t.sol";
import {Arcfloat} from "../Arcfloat.sol";
import {MockOddToken} from "./mocks/MockOddToken.sol";

/// Funding, withdrawals, cancellation and refunds.
contract ArcfloatFundTest is ArcfloatTestBase {
    // ---------------- fund ----------------
    function test_Fund_SingleFunderCompletesAndAdvanceReachesFreelancer() public {
        uint256 id = _createStd();
        uint256 flBefore = _bal(freelancer);
        uint256 fBefore = _bal(funders[0]);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.ContributionAdded(id, funders[0], TARGET, TARGET);
        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoiceFunded(id);
        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.AdvanceReleased(id, freelancer, TARGET);
        uint256 accepted = _fund(id, funders[0], TARGET);

        assertEq(accepted, TARGET);
        assertEq(_bal(freelancer), flBefore + TARGET);
        assertEq(_bal(funders[0]), fBefore - TARGET);
        assertEq(_bal(address(af)), 0);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        assertEq(af.contributionOf(id, funders[0]), TARGET);
        assertEq(af.getInvoice(id).freelancerOwed, 0);
        assertEq(af.getInvoice(id).unclaimedFunders, 1);
        assertEq(af.outstanding(id), 0);
    }

    function test_Fund_TwoFundersCoFund() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 600e6);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Open));
        assertEq(_bal(address(af)), 600e6);
        assertEq(af.outstanding(id), 600e6);
        assertEq(_bal(freelancer), 0);

        _fund(id, funders[1], 350e6);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        assertEq(_bal(freelancer), TARGET);
        assertEq(_bal(address(af)), 0);
        assertEq(af.getInvoice(id).funderCount, 2);
        assertEq(af.getInvoice(id).unclaimedFunders, 2);
        assertEq(af.contributionOf(id, funders[0]), 600e6);
        assertEq(af.contributionOf(id, funders[1]), 350e6);
    }

    function test_Fund_OverFundingIsCappedAndOnlyAcceptedPulled() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 400e6);
        uint256 before1 = _bal(funders[1]);

        uint256 accepted = _fund(id, funders[1], 5_000e6);

        assertEq(accepted, 550e6);
        assertEq(before1 - _bal(funders[1]), 550e6);
        assertEq(af.contributionOf(id, funders[1]), 550e6);
        assertEq(af.getInvoice(id).totalFunded, TARGET);
        assertEq(_bal(freelancer), TARGET);
        assertEq(_bal(address(af)), 0);
    }

    function test_Fund_SameFunderTopUpKeepsFunderCount() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 100e6);
        _fund(id, funders[0], 100e6);
        assertEq(af.getInvoice(id).funderCount, 1);
        assertEq(af.contributionOf(id, funders[0]), 200e6);
    }

    function test_Fund_BelowMinimumRevertsButMinimumWorks() public {
        uint256 id = _createStd();
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.ContributionTooSmall.selector);
        af.fund(id, 9_999);
        assertEq(_fund(id, funders[0], 10_000), 10_000);
    }

    function test_Fund_SmallFinalSliceCompletesTarget() public {
        uint256 id = _createStd();
        _fund(id, funders[0], TARGET - 5_000);
        // Below the minimum but equals the remaining -> allowed and completes.
        vm.prank(funders[1]);
        vm.expectRevert(Arcfloat.ContributionTooSmall.selector);
        af.fund(id, 4_999); // does not complete: remaining is 5_000
        uint256 accepted = _fund(id, funders[1], 1e6); // capped to remaining 5_000
        assertEq(accepted, 5_000);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        assertEq(_bal(freelancer), TARGET);
    }

    function test_Fund_ZeroAmountReverts() public {
        uint256 id = _createStd();
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.ZeroAmount.selector);
        af.fund(id, 0);
    }

    function test_Fund_EleventhFunderRevertsTooMany() public {
        uint256 id = _createStd();
        for (uint256 i; i < 10; ++i) _fund(id, funders[i], 10e6);
        assertEq(af.getInvoice(id).funderCount, 10);
        vm.prank(funders[10]);
        vm.expectRevert(Arcfloat.TooManyFunders.selector);
        af.fund(id, 10e6);
        // Existing funder can still top up at the cap.
        _fund(id, funders[0], 10e6);
        assertEq(af.getInvoice(id).funderCount, 10);
    }

    function test_Fund_TenFundersCanCompleteTarget() public {
        uint256 id = _createStd();
        for (uint256 i; i < 10; ++i) _fund(id, funders[i], 95e6);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        assertEq(af.getInvoice(id).funderCount, 10);
        assertEq(af.getInvoice(id).unclaimedFunders, 10);
        assertEq(_bal(freelancer), TARGET);
    }

    function test_Fund_RevertsAfterDueDateButWorksAtDueDate() public {
        uint256 id = _createStd();
        uint64 due = af.getInvoice(id).dueDate;
        vm.warp(due); // now == dueDate still allowed
        _fund(id, funders[0], 10e6);
        vm.warp(due + 1);
        vm.prank(funders[1]);
        vm.expectRevert(Arcfloat.FundingClosed.selector);
        af.fund(id, 10e6);
    }

    function test_Fund_RevertsWhenNotOpen() public {
        uint256 id = _fundedStd();
        vm.prank(funders[5]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.fund(id, 10e6);
    }

    function test_Fund_RevertsOnFeeOnTransferToken() public {
        MockOddToken fee = new MockOddToken(6, 100); // 1% fee
        Arcfloat a = new Arcfloat(address(fee));
        fee.mint(funders[0], 10_000e6);
        vm.prank(funders[0]);
        fee.approve(address(a), type(uint256).max);
        vm.prank(freelancer);
        uint256 id = a.createInvoice(client, FACE, uint64(block.timestamp + 1 days), BPS);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.UnexpectedTokenBalanceDelta.selector);
        a.fund(id, 100e6);
    }

    // ---------------- withdrawContribution ----------------
    function test_Withdraw_ReturnsContributionWhileOpen() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 300e6);
        _fund(id, funders[1], 200e6);
        uint256 before0 = _bal(funders[0]);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.ContributionWithdrawn(id, funders[0], 300e6);
        vm.prank(funders[0]);
        af.withdrawContribution(id);

        assertEq(_bal(funders[0]), before0 + 300e6);
        assertEq(af.contributionOf(id, funders[0]), 0);
        assertEq(af.getInvoice(id).totalFunded, 200e6);
        assertEq(af.getInvoice(id).funderCount, 1);
        assertEq(af.outstanding(id), 200e6);
        assertEq(_bal(address(af)), 200e6);
    }

    function test_Withdraw_FreesFunderSlotAtCap() public {
        uint256 id = _createStd();
        for (uint256 i; i < 10; ++i) _fund(id, funders[i], 10e6);
        vm.prank(funders[3]);
        af.withdrawContribution(id);
        _fund(id, funders[10], 10e6); // slot reusable
        assertEq(af.getInvoice(id).funderCount, 10);
    }

    function test_Withdraw_RevertsForNonContributorAndTwice() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 100e6);
        vm.prank(stranger);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.withdrawContribution(id);
        vm.startPrank(funders[0]);
        af.withdrawContribution(id);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.withdrawContribution(id);
        vm.stopPrank();
    }

    function test_Withdraw_RevertsAfterFunded() public {
        uint256 id = _fundedStd();
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.withdrawContribution(id);
    }

    // ---------------- cancel + refunds ----------------
    function test_Cancel_ThenExactRefundsAndZeroBalance() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 123_456_789);
        _fund(id, funders[1], 10_000);
        uint256 b0 = _bal(funders[0]);
        uint256 b1 = _bal(funders[1]);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoiceCancelled(id);
        vm.prank(freelancer);
        af.cancelInvoice(id);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Cancelled));
        assertEq(af.getInvoice(id).refundPool, 123_466_789);
        assertEq(af.outstanding(id), 123_466_789);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.RefundClaimed(id, funders[0], 123_456_789);
        vm.prank(funders[0]);
        af.claimRefund(id);
        vm.prank(funders[1]);
        af.claimRefund(id);

        assertEq(_bal(funders[0]), b0 + 123_456_789);
        assertEq(_bal(funders[1]), b1 + 10_000);
        assertEq(_bal(address(af)), 0);
        assertEq(af.outstanding(id), 0);
        assertTrue(af.isSettled(id, funders[0]));
    }

    function test_Cancel_OnlyFreelancer() public {
        uint256 id = _createStd();
        vm.prank(client);
        vm.expectRevert(Arcfloat.NotFreelancer.selector);
        af.cancelInvoice(id);
        vm.prank(stranger);
        vm.expectRevert(Arcfloat.NotFreelancer.selector);
        af.cancelInvoice(id);
    }

    function test_Cancel_RevertsOnceFundedOrAlreadyCancelled() public {
        uint256 funded = _fundedStd();
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.cancelInvoice(funded);

        uint256 id = _createStd();
        vm.startPrank(freelancer);
        af.cancelInvoice(id);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.cancelInvoice(id);
        vm.stopPrank();
    }

    function test_Cancel_BlocksFundingWithdrawalAndPayment() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 100e6);
        vm.prank(freelancer);
        af.cancelInvoice(id);
        vm.prank(funders[1]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.fund(id, 10e6);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.withdrawContribution(id);
        vm.prank(client);
        vm.expectRevert(Arcfloat.WrongStatus.selector);
        af.payInvoice(id);
    }

    function test_Refund_DoubleClaimAndNonEntitledAndWrongStatus() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 100e6);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.WrongStatus.selector); // still Open
        af.claimRefund(id);
        vm.prank(freelancer);
        af.cancelInvoice(id);

        vm.prank(stranger);
        vm.expectRevert(Arcfloat.NotEntitled.selector);
        af.claimRefund(id);

        vm.startPrank(funders[0]);
        af.claimRefund(id);
        vm.expectRevert(Arcfloat.AlreadyClaimed.selector);
        af.claimRefund(id);
        vm.stopPrank();
    }

    function test_Refund_CancelledWithNoFundersIsHarmless() public {
        uint256 id = _createStd();
        vm.prank(freelancer);
        af.cancelInvoice(id);
        assertEq(af.outstanding(id), 0);
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.NothingToClaim.selector);
        af.claimFreelancer(id);
    }
}
