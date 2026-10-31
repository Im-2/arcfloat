// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Arcfloat
/// @notice Non-recourse, co-funded USDC invoice advances with pull-based settlement.
/// @dev All amounts use the USDC ERC-20 interface's six-decimal base units, never
/// native gas-token units. No administrator, fees, upgrades, or funder recovery
/// against a freelancer exists. Only the configured USDC contract is called.
contract Arcfloat is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_DISCOUNT_BPS = 50;
    uint256 public constant MAX_DISCOUNT_BPS = 2_000;
    uint256 public constant MIN_FACE_AMOUNT = 1e6;
    uint256 public constant MIN_CONTRIBUTION = 10_000;
    uint256 public constant MAX_FUNDERS = 10;

    enum Status { None, Open, Funded, Paid, Cancelled, Defaulted }

    struct Invoice {
        address freelancer;
        address client;
        uint128 faceAmount;
        uint128 advanceTarget;
        uint128 totalFunded;
        uint128 repaymentPool;
        uint128 freelancerOwed;
        uint128 refundPool;
        uint64 dueDate;
        uint16 discountBps;
        uint8 funderCount;
        Status status;
        bool paidBeforeFunded;
        uint8 unclaimedFunders;
    }

    IERC20 public immutable usdc;
    uint256 public nextInvoiceId = 1;
    mapping(uint256 => Invoice) private invoices;
    mapping(uint256 => mapping(address => uint128)) private contribution;
    mapping(uint256 => mapping(address => bool)) private settled;

    error ZeroAddress();
    error TokenHasNoCode();
    error InvalidTokenDecimals(uint8 decimals);
    error InvalidFaceAmount();
    error InvalidDiscountBps();
    error InvalidDueDate();
    error InvoiceNotFound();
    error WrongStatus();
    error FundingClosed();
    error ZeroAmount();
    error ContributionTooSmall();
    error TooManyFunders();
    error NotEntitled();
    error NotFreelancer();
    error NotClient();
    error AlreadyClaimed();
    error NothingToClaim();
    error NotOverdue();
    error UnexpectedTokenBalanceDelta();

    event USDCConfigured(address indexed usdc);
    event InvoiceCreated(
        uint256 indexed id, address indexed freelancer, address indexed client,
        uint256 faceAmount, uint256 advanceTarget, uint64 dueDate, uint16 discountBps
    );
    event ContributionAdded(uint256 indexed id, address indexed funder, uint256 accepted, uint256 totalFunded);
    event AdvanceReleased(uint256 indexed id, address indexed freelancer, uint256 amount);
    event AdvanceDeferred(uint256 indexed id, address indexed freelancer, uint256 amount);
    event InvoiceFunded(uint256 indexed id);
    event ContributionWithdrawn(uint256 indexed id, address indexed funder, uint256 amount);
    event InvoiceCancelled(uint256 indexed id);
    event InvoicePaid(uint256 indexed id, address indexed client, uint256 faceAmount, bool paidBeforeFunded);
    event RepaymentClaimed(uint256 indexed id, address indexed funder, uint256 amount);
    event FreelancerClaimed(uint256 indexed id, address indexed freelancer, uint256 amount);
    event RefundClaimed(uint256 indexed id, address indexed funder, uint256 amount);
    event InvoiceDefaulted(uint256 indexed id, uint256 timestamp);

    /// @notice Configure the immutable six-decimal USDC ERC-20 token.
    /// @dev Canonical Arc testnet and mainnet USDC ERC-20 address:
    /// 0x3600000000000000000000000000000000000000, documented at
    /// https://docs.arc.io/arc/references/contract-addresses.md .
    /// This address is documentation only; deployment always supplies usdc_.
    /// @param usdc_ Token contract address, not a native-token accounting handle.
    constructor(address usdc_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        if (usdc_.code.length == 0) revert TokenHasNoCode();
        uint8 tokenDecimals = IERC20Metadata(usdc_).decimals();
        if (tokenDecimals != 6) revert InvalidTokenDecimals(tokenDecimals);
        usdc = IERC20(usdc_);
        emit USDCConfigured(usdc_);
    }

    /// @notice Create an invoice as its freelancer, with an immutable client and terms.
    /// @return id Newly allocated invoice identifier, starting at one.
    function createInvoice(address client, uint256 faceAmount, uint64 dueDate, uint16 discountBps)
        external nonReentrant returns (uint256 id)
    {
        if (client == address(0)) revert ZeroAddress();
        uint256 advanceTarget = quoteAdvance(faceAmount, discountBps);
        if (dueDate <= block.timestamp) revert InvalidDueDate();

        id = nextInvoiceId++;
        Invoice storage invoice = invoices[id];
        invoice.freelancer = msg.sender;
        invoice.client = client;
        invoice.faceAmount = uint128(faceAmount);
        invoice.advanceTarget = uint128(advanceTarget);
        invoice.dueDate = dueDate;
        invoice.discountBps = discountBps;
        invoice.status = Status.Open;
        emit InvoiceCreated(id, msg.sender, client, faceAmount, advanceTarget, dueDate, discountBps);
    }

    /// @notice Contribute up to the remaining advance and immediately release a completed advance.
    /// @dev Only accepted tokens are pulled. The final slice may be below the minimum.
    /// @return accepted Actual contribution after capping at the remaining advance.
    function fund(uint256 id, uint256 amount) external nonReentrant returns (uint256 accepted) {
        Invoice storage invoice = _invoice(id);
        if (invoice.status != Status.Open) revert WrongStatus();
        if (block.timestamp > invoice.dueDate) revert FundingClosed();
        if (amount == 0) revert ZeroAmount();
        uint256 remaining = uint256(invoice.advanceTarget) - invoice.totalFunded;
        accepted = amount < remaining ? amount : remaining;
        if (accepted < MIN_CONTRIBUTION && accepted != remaining) revert ContributionTooSmall();
        if (contribution[id][msg.sender] == 0) {
            if (invoice.funderCount >= MAX_FUNDERS) revert TooManyFunders();
            invoice.funderCount++;
        }
        contribution[id][msg.sender] += uint128(accepted);
        invoice.totalFunded += uint128(accepted);
        bool complete = invoice.totalFunded == invoice.advanceTarget;
        if (complete) {
            invoice.status = Status.Funded;
            invoice.unclaimedFunders = invoice.funderCount;
        }
        emit ContributionAdded(id, msg.sender, accepted, invoice.totalFunded);
        _pullExact(msg.sender, accepted);
        if (complete) {
            emit InvoiceFunded(id);
            _releaseAdvance(id, invoice);
        }
    }

    /// @notice Withdraw all of your contribution while the invoice remains Open.
    function withdrawContribution(uint256 id) external nonReentrant {
        Invoice storage invoice = _invoice(id);
        if (invoice.status != Status.Open) revert WrongStatus();
        uint128 amount = contribution[id][msg.sender];
        if (amount == 0) revert NotEntitled();
        contribution[id][msg.sender] = 0;
        invoice.totalFunded -= amount;
        invoice.funderCount--;
        emit ContributionWithdrawn(id, msg.sender, amount);
        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Cancel your Open invoice and make all contributions refundable.
    function cancelInvoice(uint256 id) external nonReentrant {
        Invoice storage invoice = _invoice(id);
        if (msg.sender != invoice.freelancer) revert NotFreelancer();
        if (invoice.status != Status.Open) revert WrongStatus();
        invoice.status = Status.Cancelled;
        invoice.refundPool = invoice.totalFunded;
        emit InvoiceCancelled(id);
    }

    /// @notice Pay the full face amount as the designated client, including after default.
    /// @dev Funded-path shares distribute the entire face amount to funders: the
    /// freelancer's remainder is zero because the advance was already released.
    /// Paying while Open instead reserves the face amount for the freelancer and
    /// separately refunds all partial contributions. Approval is required first.
    function payInvoice(uint256 id) external nonReentrant {
        Invoice storage invoice = _invoice(id);
        if (msg.sender != invoice.client) revert NotClient();
        Status previous = invoice.status;
        if (previous != Status.Open && previous != Status.Funded && previous != Status.Defaulted) {
            revert WrongStatus();
        }
        bool beforeFunded = previous == Status.Open;
        invoice.status = Status.Paid;
        invoice.paidBeforeFunded = beforeFunded;
        if (beforeFunded) {
            invoice.freelancerOwed = invoice.faceAmount;
            invoice.refundPool = invoice.totalFunded;
            invoice.repaymentPool = 0;
        } else {
            // freelancerOwed is left untouched: it only holds an advance whose
            // push release failed, which the freelancer can still claim.
            invoice.repaymentPool = invoice.faceAmount;
        }
        emit InvoicePaid(id, msg.sender, invoice.faceAmount, beforeFunded);
        _pullExact(msg.sender, invoice.faceAmount);
    }

    /// @notice Claim your proportional repayment from a funded-path Paid invoice.
    /// @dev Last claimant receives all remaining rounding dust. There are no loops
    /// or cross-recipient transfers, so a blocked recipient cannot block others.
    function claimRepayment(uint256 id) external nonReentrant {
        Invoice storage invoice = _invoice(id);
        if (invoice.status != Status.Paid || invoice.paidBeforeFunded) revert WrongStatus();
        uint128 amountContributed = contribution[id][msg.sender];
        if (amountContributed == 0) revert NotEntitled();
        if (settled[id][msg.sender]) revert AlreadyClaimed();
        uint256 share = uint256(invoice.faceAmount) * amountContributed / invoice.advanceTarget;
        settled[id][msg.sender] = true;
        invoice.unclaimedFunders--;
        uint256 payout = invoice.unclaimedFunders == 0 ? invoice.repaymentPool : share;
        invoice.repaymentPool -= uint128(payout);
        emit RepaymentClaimed(id, msg.sender, payout);
        usdc.safeTransfer(msg.sender, payout);
    }

    /// @notice Claim your invoice's reserved freelancer payment, if any: a deferred
    /// advance (when the automatic release failed) or the full face amount after
    /// the client paid before the invoice was fully funded.
    function claimFreelancer(uint256 id) external nonReentrant {
        Invoice storage invoice = _invoice(id);
        if (msg.sender != invoice.freelancer) revert NotEntitled();
        uint128 amount = invoice.freelancerOwed;
        if (amount == 0) revert NothingToClaim();
        invoice.freelancerOwed = 0;
        emit FreelancerClaimed(id, msg.sender, amount);
        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Recover your contribution after cancellation or payment before funding.
    function claimRefund(uint256 id) external nonReentrant {
        Invoice storage invoice = _invoice(id);
        if (invoice.status != Status.Cancelled && !(invoice.status == Status.Paid && invoice.paidBeforeFunded)) {
            revert WrongStatus();
        }
        uint128 amount = contribution[id][msg.sender];
        if (amount == 0) revert NotEntitled();
        if (settled[id][msg.sender]) revert AlreadyClaimed();
        settled[id][msg.sender] = true;
        invoice.refundPool -= amount;
        emit RefundClaimed(id, msg.sender, amount);
        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Record an overdue funded invoice without moving funds or preventing late payment.
    function markDefaulted(uint256 id) external nonReentrant {
        Invoice storage invoice = _invoice(id);
        if (invoice.status != Status.Funded) revert WrongStatus();
        if (block.timestamp <= invoice.dueDate) revert NotOverdue();
        invoice.status = Status.Defaulted;
        emit InvoiceDefaulted(id, block.timestamp);
    }

    /// @notice Return the number of invoices created, including closed invoices.
    function invoiceCount() external view returns (uint256) {
        return nextInvoiceId - 1;
    }

    /// @notice Return an existing invoice, reverting if the identifier was never created.
    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return _invoice(id);
    }

    /// @notice Return the recorded contribution; settled contributions remain recorded.
    function contributionOf(uint256 id, address account) external view returns (uint128) {
        return contribution[id][account];
    }

    /// @notice Return whether the account has claimed its refund or repayment.
    function isSettled(uint256 id, address account) external view returns (bool) {
        return settled[id][account];
    }

    /// @notice Return the exact repayment available now, including last-claimant dust.
    /// @dev Returns zero for nonexistent invoices and all other nonclaimable cases.
    function claimableRepayment(uint256 id, address account) external view returns (uint256) {
        Invoice storage invoice = invoices[id];
        if (invoice.status != Status.Paid || invoice.paidBeforeFunded || settled[id][account]) return 0;
        uint128 amount = contribution[id][account];
        if (amount == 0) return 0;
        if (invoice.unclaimedFunders == 1) return invoice.repaymentPool;
        return uint256(invoice.faceAmount) * amount / invoice.advanceTarget;
    }

    /// @notice Quote a rounded-down advance using the same amount and discount bounds as creation.
    function quoteAdvance(uint256 face, uint16 bps) public pure returns (uint256) {
        if (face < MIN_FACE_AMOUNT || face > type(uint128).max) revert InvalidFaceAmount();
        if (bps < MIN_DISCOUNT_BPS || bps > MAX_DISCOUNT_BPS) revert InvalidDiscountBps();
        return face * (BPS_DENOMINATOR - bps) / BPS_DENOMINATOR;
    }

    /// @notice Return the USDC base units still reserved for this invoice.
    /// @dev Unsolicited token transfers are not assigned to any invoice.
    function outstanding(uint256 id) external view returns (uint256) {
        Invoice storage invoice = invoices[id];
        if (invoice.status == Status.Open) return invoice.totalFunded;
        if (invoice.status == Status.Paid) {
            return uint256(invoice.repaymentPool) + invoice.freelancerOwed + invoice.refundPool;
        }
        if (invoice.status == Status.Cancelled) return invoice.refundPool;
        // Funded / Defaulted: only an advance whose automatic release failed.
        return invoice.freelancerOwed;
    }

    /// @dev Resolve an existing invoice without changing storage.
    function _invoice(uint256 id) private view returns (Invoice storage invoice) {
        invoice = invoices[id];
        if (invoice.status == Status.None) revert InvoiceNotFound();
    }

    /// @dev Try to push the completed advance to the freelancer. A failing recipient
    /// (for example a blocklisted address) must never block funding, so on failure
    /// the advance stays reserved in freelancerOwed for a later claimFreelancer.
    function _releaseAdvance(uint256 id, Invoice storage invoice) private {
        uint128 amount = invoice.advanceTarget;
        address freelancer = invoice.freelancer;
        bool released = false;
        try usdc.transfer(freelancer, amount) returns (bool ok) {
            released = ok;
        } catch {
            released = false;
        }
        if (released) {
            emit AdvanceReleased(id, freelancer, amount);
        } else {
            invoice.freelancerOwed = amount;
            emit AdvanceDeferred(id, freelancer, amount);
        }
    }

    /// @dev Reject any incoming transfer whose observed balance increase is not exact.
    function _pullExact(address from, uint256 amount) private {
        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = usdc.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert UnexpectedTokenBalanceDelta();
        }
    }
}
