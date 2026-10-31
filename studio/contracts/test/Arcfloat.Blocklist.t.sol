// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArcfloatTestBase} from "./Arcfloat.Base.t.sol";
import {Arcfloat} from "../Arcfloat.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Blocklist (Arc USDC compliance) behaviour: no recipient can block anyone else.
contract ArcfloatBlocklistTest is ArcfloatTestBase {
    uint256 internal constant S0 = 526_315_789;
    uint256 internal constant S1 = 315_789_473;
    uint256 internal constant S2 = 157_894_736;

    function _block(address a) internal {
        usdc.setBlocklisted(a, true);
    }

    function _unblock(address a) internal {
        usdc.setBlocklisted(a, false);
    }

    function _blockedErr(address a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockUSDC.Blocklisted.selector, a);
    }

    // ---------------- blocklisted funder ----------------
    function test_BlockedFunderClaimFailsWithoutBlockingOthers() public {
        uint256 id = _fundedStd();
        _pay(id);
        _block(funders[1]);

        vm.prank(funders[1]);
        vm.expectRevert(_blockedErr(funders[1]));
        af.claimRepayment(id);
        assertFalse(af.isSettled(id, funders[1])); // failed claim fully rolled back

        assertEq(_claimRepayment(id, funders[0]), S0);
        // funders[2] is the last unclaimed *claimant*? No: funders[1] still unclaimed.
        assertEq(_claimRepayment(id, funders[2]), S2);
        // funders[1] still owed share + dust; contract holds exactly that.
        assertEq(_bal(address(af)), S1 + 2);
        assertEq(af.outstanding(id), S1 + 2);
        assertEq(af.claimableRepayment(id, funders[1]), S1 + 2);

        _unblock(funders[1]);
        assertEq(_claimRepayment(id, funders[1]), S1 + 2);
        assertEq(_bal(address(af)), 0);
    }

    function test_BlockedFunderHoldingTheDust_OthersStillClaimTheirShares() public {
        uint256 id = _fundedStd();
        _pay(id);
        _block(funders[2]);

        assertEq(_claimRepayment(id, funders[0]), S0);
        assertEq(_claimRepayment(id, funders[1]), S1);
        vm.prank(funders[2]);
        vm.expectRevert(_blockedErr(funders[2]));
        af.claimRepayment(id);
        assertEq(_bal(address(af)), S2 + 2);

        _unblock(funders[2]);
        assertEq(_claimRepayment(id, funders[2]), S2 + 2);
        assertEq(_bal(address(af)), 0);
    }

    function test_BlockedFunderRefundFailsOthersUnaffected() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 100e6);
        _fund(id, funders[1], 200e6);
        vm.prank(freelancer);
        af.cancelInvoice(id);
        _block(funders[0]);

        vm.prank(funders[0]);
        vm.expectRevert(_blockedErr(funders[0]));
        af.claimRefund(id);
        uint256 b1 = _bal(funders[1]);
        vm.prank(funders[1]);
        af.claimRefund(id);
        assertEq(_bal(funders[1]), b1 + 200e6);
        assertEq(_bal(address(af)), 100e6);

        _unblock(funders[0]);
        vm.prank(funders[0]);
        af.claimRefund(id);
        assertEq(_bal(address(af)), 0);
    }

    function test_BlockedFunderDoesNotBlockFundingCompletion() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 100e6);
        _block(funders[0]);
        // Other funders complete the invoice regardless.
        _fund(id, funders[1], TARGET - 100e6);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        assertEq(_bal(freelancer), TARGET);
    }

    // ---------------- blocklisted freelancer ----------------
    function test_BlockedFreelancerDoesNotBlockFundingAdvanceDeferred() public {
        uint256 id = _createStd();
        _fund(id, funders[0], 400e6);
        _block(freelancer);

        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoiceFunded(id);
        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.AdvanceDeferred(id, freelancer, TARGET);
        _fund(id, funders[1], 550e6);

        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        assertEq(_bal(freelancer), 0);
        assertEq(af.getInvoice(id).freelancerOwed, TARGET);
        assertEq(_bal(address(af)), TARGET);
        assertEq(af.outstanding(id), TARGET);

        vm.prank(freelancer);
        vm.expectRevert(_blockedErr(freelancer));
        af.claimFreelancer(id);
        assertEq(af.getInvoice(id).freelancerOwed, TARGET); // rolled back

        _unblock(freelancer);
        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.FreelancerClaimed(id, freelancer, TARGET);
        vm.prank(freelancer);
        af.claimFreelancer(id);
        assertEq(_bal(freelancer), TARGET);
        assertEq(_bal(address(af)), 0);
        assertEq(af.outstanding(id), 0);

        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.NothingToClaim.selector);
        af.claimFreelancer(id);
    }

    function test_BlockedFreelancer_PaymentAndRepaymentStillConserveFunds() public {
        uint256 id = _createStd();
        _block(freelancer);
        _fund(id, funders[0], 500e6);
        _fund(id, funders[1], 300e6);
        _fund(id, funders[2], 150e6);
        _pay(id);
        // advance still reserved + full face held
        assertEq(_bal(address(af)), TARGET + FACE);
        assertEq(af.outstanding(id), TARGET + FACE);

        assertEq(_claimRepayment(id, funders[0]), S0);
        assertEq(_claimRepayment(id, funders[1]), S1);
        assertEq(_claimRepayment(id, funders[2]), S2 + 2);
        assertEq(_bal(address(af)), TARGET);

        _unblock(freelancer);
        vm.prank(freelancer);
        af.claimFreelancer(id);
        assertEq(_bal(freelancer), TARGET);
        assertEq(_bal(address(af)), 0);
    }

    // ---------------- blocklisted client ----------------
    function test_BlockedClientCannotPayUntilUnblocked() public {
        uint256 id = _fundedStd();
        _block(client);
        vm.prank(client);
        vm.expectRevert(_blockedErr(client));
        af.payInvoice(id);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Funded));
        _unblock(client);
        _pay(id);
        assertEq(uint8(_status(id)), uint8(Arcfloat.Status.Paid));
    }
}
