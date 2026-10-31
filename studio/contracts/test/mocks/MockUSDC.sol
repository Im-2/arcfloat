// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test double mimicking Arc USDC: 6 decimals, open mint, and a blocklist that
/// makes transfer/transferFrom revert when the sender or the recipient is blocklisted.
contract MockUSDC is ERC20 {
    mapping(address => bool) public blocklisted;

    error Blocklisted(address account);

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocklisted(address account, bool status) external {
        blocklisted[account] = status;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _checkBlocklist(msg.sender, to);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _checkBlocklist(from, to);
        return super.transferFrom(from, to, value);
    }

    function _checkBlocklist(address from, address to) internal view {
        if (blocklisted[from]) revert Blocklisted(from);
        if (blocklisted[to]) revert Blocklisted(to);
    }
}
