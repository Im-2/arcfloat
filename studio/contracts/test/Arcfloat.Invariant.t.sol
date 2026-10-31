// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Arcfloat} from "../Arcfloat.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Drives random, bounded protocol actions across several actors and invoices.
/// Every call is wrapped in try/catch so reverting paths are explored without aborting.
contract ArcfloatHandler is Test {
    Arcfloat public af;
    MockUSDC public usdc;
    address[] public actors;
    uint256[] public ids;

    /// Net USDC flow into the contract per invoice, measured from balance deltas.
    mapping(uint256 => int256) public ghostNet;
    uint256 public callsOk;
    uint256 public claims;
    bool public claimOverdrew; // a claim ever increased the contract balance or exceeded holdings

    constructor(Arcfloat _af, MockUSDC _usdc) {
        af = _af;
        usdc = _usdc;
        for (uint256 i; i < 6; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            usdc.mint(a, 1e15);
            vm.prank(a);
            usdc.approve(address(_af), type(uint256).max);
        }
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _id(uint256 seed) internal view returns (uint256) {
        if (ids.length == 0) return 0;
        // bias toward the most recent invoices so lifecycles actually progress
        uint256 window = ids.length < 3 ? ids.length : 3;
        return ids[ids.length - 1 - (seed % window)];
    }

    function _bal() internal view returns (uint256) {
        return usdc.balanceOf(address(af));
    }

    function _record(uint256 id, uint256 beforeBal) internal {
        ghostNet[id] += int256(_bal()) - int256(beforeBal);
    }

    // ----- actions -----
    function create(uint256 fSeed, uint256 cSeed, uint256 face, uint256 bps, uint256 dueOff) external {
        face = bound(face, 1e6, 1e9);
        bps = bound(bps, 50, 2000);
        dueOff = bound(dueOff, 3 days, 30 days);
        vm.prank(_actor(fSeed));
        try af.createInvoice(_actor(cSeed), face, uint64(block.timestamp + dueOff), uint16(bps)) returns (uint256 id) {
            ids.push(id);
            callsOk++;
        } catch {}
    }

    function fund(uint256 idSeed, uint256 aSeed, uint256 amount) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        amount = bound(amount, 10_000, af.getInvoice(id).advanceTarget);
        uint256 b = _bal();
        vm.prank(_actor(aSeed));
        try af.fund(id, amount) { callsOk++; } catch {}
        _record(id, b);
    }

    function withdraw(uint256 idSeed, uint256 aSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0 || aSeed % 3 != 0) return; // rare, so funding can complete
        uint256 b = _bal();
        vm.prank(_actor(aSeed));
        try af.withdrawContribution(id) { callsOk++; } catch {}
        _record(id, b);
    }

    function cancel(uint256 idSeed, uint256 gate) external {
        uint256 id = _id(idSeed);
        if (id == 0 || gate % 4 != 0) return; // rare
        address fl = af.getInvoice(id).freelancer;
        uint256 b = _bal();
        vm.prank(fl);
        try af.cancelInvoice(id) { callsOk++; } catch {}
        _record(id, b);
    }

    function pay(uint256 idSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        address c = af.getInvoice(id).client;
        uint256 b = _bal();
        vm.prank(c);
        try af.payInvoice(id) { callsOk++; } catch {}
        _record(id, b);
    }

    function claimRepayment(uint256 idSeed, uint256 aSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        uint256 b = _bal();
        vm.prank(_actor(aSeed));
        try af.claimRepayment(id) { callsOk++; claims++; } catch {}
        _afterClaim(id, b);
    }

    function claimRefund(uint256 idSeed, uint256 aSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        uint256 b = _bal();
        vm.prank(_actor(aSeed));
        try af.claimRefund(id) { callsOk++; claims++; } catch {}
        _afterClaim(id, b);
    }

    function claimFreelancer(uint256 idSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        address fl = af.getInvoice(id).freelancer;
        uint256 b = _bal();
        vm.prank(fl);
        try af.claimFreelancer(id) { callsOk++; claims++; } catch {}
        _afterClaim(id, b);
    }

    function markDefaulted(uint256 idSeed, uint256 aSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        uint256 b = _bal();
        vm.prank(_actor(aSeed));
        try af.markDefaulted(id) { callsOk++; } catch {}
        _record(id, b);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 6 days));
    }

    function setBlocked(uint256 aSeed, bool status) external {
        usdc.setBlocklisted(_actor(aSeed), status && aSeed % 4 == 0); // blocked only sometimes
    }

    function _afterClaim(uint256 id, uint256 beforeBal) internal {
        if (_bal() > beforeBal) claimOverdrew = true; // a claim must only ever pay out
        _record(id, beforeBal);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail_on_revert = false
contract ArcfloatInvariantTest is StdInvariant, Test {
    Arcfloat internal af;
    MockUSDC internal usdc;
    ArcfloatHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        af = new Arcfloat(address(usdc));
        handler = new ArcfloatHandler(af, usdc);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](11);
        sels[0] = ArcfloatHandler.create.selector;
        sels[1] = ArcfloatHandler.fund.selector;
        sels[2] = ArcfloatHandler.withdraw.selector;
        sels[3] = ArcfloatHandler.cancel.selector;
        sels[4] = ArcfloatHandler.pay.selector;
        sels[5] = ArcfloatHandler.claimRepayment.selector;
        sels[6] = ArcfloatHandler.claimRefund.selector;
        sels[7] = ArcfloatHandler.claimFreelancer.selector;
        sels[8] = ArcfloatHandler.markDefaulted.selector;
        sels[9] = ArcfloatHandler.warp.selector;
        sels[10] = ArcfloatHandler.setBlocked.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function _sumOutstanding() internal view returns (uint256 sum) {
        uint256 n = af.invoiceCount();
        for (uint256 id = 1; id <= n; ++id) sum += af.outstanding(id);
    }

    /// Contract balance always equals what it must hold across all invoices.
    function invariant_BalanceEqualsSumOutstanding() public view {
        assertEq(usdc.balanceOf(address(af)), _sumOutstanding());
    }

    /// Per-invoice: measured net inflow equals outstanding, and is never negative
    /// (funds never go negative after any claim / release).
    function invariant_PerInvoiceFlowMatchesOutstandingAndNeverNegative() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            int256 net = handler.ghostNet(id);
            assertGe(net, 0, "negative funds");
            assertEq(uint256(net), af.outstanding(id), "flow != outstanding");
        }
    }

    function invariant_ClaimsOnlyPayOut() public view {
        assertFalse(handler.claimOverdrew());
    }

    /// Every settled position is internally consistent: accounting never exceeds face for funded-path pools.
    function invariant_RepaymentPoolNeverExceedsFace() public view {
        uint256 n = af.invoiceCount();
        for (uint256 id = 1; id <= n; ++id) {
            Arcfloat.Invoice memory inv = af.getInvoice(id);
            assertLe(inv.repaymentPool, inv.faceAmount);
            assertLe(inv.totalFunded, inv.advanceTarget);
        }
    }
}
