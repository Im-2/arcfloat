// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArcfloatTestBase} from "./Arcfloat.Base.t.sol";
import {Arcfloat} from "../Arcfloat.sol";
import {MockOddToken} from "./mocks/MockOddToken.sol";

/// Constructor, invoice creation, non-payability.
contract ArcfloatCreateTest is ArcfloatTestBase {
    // ---------------- constructor ----------------
    function test_Constructor_StoresUsdcAndEmits() public {
        vm.expectEmit(true, false, false, false);
        emit Arcfloat.USDCConfigured(address(usdc));
        Arcfloat a = new Arcfloat(address(usdc));
        assertEq(address(a.usdc()), address(usdc));
        assertEq(a.nextInvoiceId(), 1);
        assertEq(a.invoiceCount(), 0);
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(Arcfloat.ZeroAddress.selector);
        new Arcfloat(address(0));
    }

    function test_Constructor_RevertsOnNonContract() public {
        vm.expectRevert(Arcfloat.TokenHasNoCode.selector);
        new Arcfloat(makeAddr("eoa"));
    }

    function test_Constructor_RevertsOnWrongDecimals() public {
        MockOddToken t18 = new MockOddToken(18, 0);
        vm.expectRevert(abi.encodeWithSelector(Arcfloat.InvalidTokenDecimals.selector, uint8(18)));
        new Arcfloat(address(t18));
        MockOddToken t0 = new MockOddToken(0, 0);
        vm.expectRevert(abi.encodeWithSelector(Arcfloat.InvalidTokenDecimals.selector, uint8(0)));
        new Arcfloat(address(t0));
    }

    // ---------------- createInvoice ----------------
    function test_CreateInvoice_Valid() public {
        uint64 due = uint64(block.timestamp) + TERM;
        vm.expectEmit(true, true, true, true, address(af));
        emit Arcfloat.InvoiceCreated(1, freelancer, client, FACE, TARGET, due, BPS);
        vm.prank(freelancer);
        uint256 id = af.createInvoice(client, FACE, due, BPS);

        assertEq(id, 1);
        assertEq(af.nextInvoiceId(), 2);
        assertEq(af.invoiceCount(), 1);
        Arcfloat.Invoice memory inv = af.getInvoice(id);
        assertEq(inv.freelancer, freelancer);
        assertEq(inv.client, client);
        assertEq(inv.faceAmount, FACE);
        assertEq(inv.advanceTarget, TARGET);
        assertEq(inv.totalFunded, 0);
        assertEq(inv.dueDate, due);
        assertEq(inv.discountBps, BPS);
        assertEq(uint8(inv.status), uint8(Arcfloat.Status.Open));
        assertEq(af.outstanding(id), 0);
    }

    function test_CreateInvoice_IdsIncrement() public {
        assertEq(_createStd(), 1);
        assertEq(_createStd(), 2);
        assertEq(af.invoiceCount(), 2);
    }

    function test_CreateInvoice_RevertsClientZero() public {
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.ZeroAddress.selector);
        af.createInvoice(address(0), FACE, uint64(block.timestamp + 1 days), BPS);
    }

    function test_CreateInvoice_RevertsFaceBelowMin() public {
        vm.startPrank(freelancer);
        vm.expectRevert(Arcfloat.InvalidFaceAmount.selector);
        af.createInvoice(client, 1e6 - 1, uint64(block.timestamp + 1 days), BPS);
        vm.expectRevert(Arcfloat.InvalidFaceAmount.selector);
        af.createInvoice(client, 0, uint64(block.timestamp + 1 days), BPS);
        vm.stopPrank();
    }

    function test_CreateInvoice_RevertsFaceAboveUint128() public {
        vm.prank(freelancer);
        vm.expectRevert(Arcfloat.InvalidFaceAmount.selector);
        af.createInvoice(client, uint256(type(uint128).max) + 1, uint64(block.timestamp + 1 days), BPS);
    }

    function test_CreateInvoice_RevertsBpsOutOfRange() public {
        vm.startPrank(freelancer);
        vm.expectRevert(Arcfloat.InvalidDiscountBps.selector);
        af.createInvoice(client, FACE, uint64(block.timestamp + 1 days), 49);
        vm.expectRevert(Arcfloat.InvalidDiscountBps.selector);
        af.createInvoice(client, FACE, uint64(block.timestamp + 1 days), 2001);
        vm.expectRevert(Arcfloat.InvalidDiscountBps.selector);
        af.createInvoice(client, FACE, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();
    }

    function test_CreateInvoice_RevertsDueDateNotInFuture() public {
        vm.startPrank(freelancer);
        vm.expectRevert(Arcfloat.InvalidDueDate.selector);
        af.createInvoice(client, FACE, uint64(block.timestamp), BPS); // == now
        vm.expectRevert(Arcfloat.InvalidDueDate.selector);
        af.createInvoice(client, FACE, uint64(block.timestamp - 1), BPS);
        vm.expectRevert(Arcfloat.InvalidDueDate.selector);
        af.createInvoice(client, FACE, 0, BPS);
        vm.stopPrank();
    }

    function test_CreateInvoice_BoundaryValuesAccepted() public {
        vm.startPrank(freelancer);
        uint64 due = uint64(block.timestamp + 1); // now+1 is valid
        uint256 a = af.createInvoice(client, 1e6, due, 50);
        uint256 b = af.createInvoice(client, 1e6, due, 2000);
        uint256 c = af.createInvoice(client, type(uint128).max, due, 50);
        vm.stopPrank();
        assertEq(af.getInvoice(a).advanceTarget, 1e6 * 9950 / 10_000); // 995_000
        assertEq(af.getInvoice(b).advanceTarget, 800_000);
        assertEq(af.getInvoice(c).faceAmount, type(uint128).max);
        assertEq(af.getInvoice(c).advanceTarget, uint256(type(uint128).max) * 9950 / 10_000);
    }

    function test_QuoteAdvance_MatchesAndValidates() public {
        assertEq(af.quoteAdvance(FACE, BPS), TARGET);
        assertEq(af.quoteAdvance(1_000_003, 100), 990_002); // rounds down
        vm.expectRevert(Arcfloat.InvalidFaceAmount.selector);
        af.quoteAdvance(999_999, BPS);
        vm.expectRevert(Arcfloat.InvalidDiscountBps.selector);
        af.quoteAdvance(FACE, 2001);
    }

    function test_UnknownInvoiceReverts() public {
        vm.expectRevert(Arcfloat.InvoiceNotFound.selector);
        af.getInvoice(1);
        vm.prank(funders[0]);
        vm.expectRevert(Arcfloat.InvoiceNotFound.selector);
        af.fund(99, 1e6);
        vm.expectRevert(Arcfloat.InvoiceNotFound.selector);
        af.payInvoice(0);
        assertEq(af.outstanding(5), 0);
        assertEq(af.claimableRepayment(5, funders[0]), 0);
    }

    // ---------------- not payable ----------------
    function test_NotPayable_PlainValueSendReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(af).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(af).balance, 0);
    }

    function test_NotPayable_ValueCallToFunctionReverts() public {
        uint256 id = _createStd();
        vm.deal(funders[0], 1 ether);
        vm.prank(funders[0]);
        (bool ok,) = address(af).call{value: 1}(abi.encodeCall(Arcfloat.fund, (id, 1e6)));
        assertFalse(ok);
        vm.prank(freelancer);
        (ok,) = address(af).call{value: 1}(
            abi.encodeCall(Arcfloat.createInvoice, (client, FACE, uint64(block.timestamp + 1 days), BPS))
        );
        assertFalse(ok);
        assertEq(address(af).balance, 0);
    }
}
