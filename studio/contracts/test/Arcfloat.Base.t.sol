// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Arcfloat} from "../Arcfloat.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Shared fixture. Contains no test/fuzz/invariant functions.
abstract contract ArcfloatTestBase is Test {
    Arcfloat internal af;
    MockUSDC internal usdc;

    address internal freelancer = makeAddr("freelancer");
    address internal client = makeAddr("client");
    address internal stranger = makeAddr("stranger");
    address[11] internal funders;

    uint256 internal constant FACE = 1000e6;
    uint16 internal constant BPS = 500;
    uint256 internal constant TARGET = 950e6; // FACE * 9500 / 10000
    uint64 internal constant TERM = 30 days;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        af = new Arcfloat(address(usdc));

        for (uint256 i; i < funders.length; ++i) {
            funders[i] = makeAddr(string.concat("funder", vm.toString(i)));
            usdc.mint(funders[i], 1_000_000e6);
            vm.prank(funders[i]);
            usdc.approve(address(af), type(uint256).max);
        }
        usdc.mint(client, 1_000_000_000e6);
        vm.prank(client);
        usdc.approve(address(af), type(uint256).max);
    }

    function _create(uint256 face, uint16 bps) internal returns (uint256 id) {
        vm.prank(freelancer);
        id = af.createInvoice(client, face, uint64(block.timestamp) + TERM, bps);
    }

    function _createStd() internal returns (uint256) {
        return _create(FACE, BPS);
    }

    function _fund(uint256 id, address who, uint256 amount) internal returns (uint256 accepted) {
        vm.prank(who);
        accepted = af.fund(id, amount);
    }

    /// @dev FACE/BPS invoice funded 500e6 / 300e6 / 150e6 by funders[0..2].
    function _fundedStd() internal returns (uint256 id) {
        id = _createStd();
        _fund(id, funders[0], 500e6);
        _fund(id, funders[1], 300e6);
        _fund(id, funders[2], 150e6);
    }

    function _pay(uint256 id) internal {
        vm.prank(client);
        af.payInvoice(id);
    }

    function _claimRepayment(uint256 id, address who) internal returns (uint256 got) {
        uint256 b = usdc.balanceOf(who);
        vm.prank(who);
        af.claimRepayment(id);
        got = usdc.balanceOf(who) - b;
    }

    function _bal(address a) internal view returns (uint256) {
        return usdc.balanceOf(a);
    }

    function _status(uint256 id) internal view returns (Arcfloat.Status) {
        return af.getInvoice(id).status;
    }
}
