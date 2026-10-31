// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Configurable-decimals token with an optional fee-on-transfer (in bps, burned
/// from the amount received). Used to check constructor decimals and delta rejection.
contract MockOddToken is ERC20 {
    uint8 private immutable _dec;
    uint256 public immutable feeBps;

    constructor(uint8 dec_, uint256 feeBps_) ERC20("Odd", "ODD") {
        _dec = dec_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0), fee); // burn the fee
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
