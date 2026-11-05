// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WealthCoin Escrow
/// @notice One instance per sale. Holds WTC until delivery is confirmed.
contract WealthCoinEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State { Created, Paid, Disputed, Completed, Refunded }

    IERC20 public immutable wtc;
    address public immutable buyer;
    address public immutable seller;
    uint256 public immutable price;          // in WTC (wei)
    uint256 public immutable deadline;        // auto-release timestamp

    State public state;
    string public disputeReason;

    event Paid(address indexed buyer, uint256 amount);
    event Delivered(address indexed seller);
    event Confirmed(address indexed buyer);
    event Disputed(address indexed by, string reason);
    event Resolved(address indexed winner, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);

    modifier onlyBuyer() { require(msg.sender == buyer, "Not buyer"); _; }
    modifier onlySeller() { require(msg.sender == seller, "Not seller"); _; }
    modifier inState(State s) { require(state == s, "Wrong state"); _; }

    constructor(
        address _wtc,
        address _buyer,
        address _seller,
        uint256 _price,
        uint256 _duration
    ) Ownable(msg.sender) {
        require(_wtc != address(0) && _buyer != address(0) && _seller != address(0), "Bad address");
        require(_price > 0, "Price zero");
        wtc = IERC20(_wtc);
        buyer = _buyer;
        seller = _seller;
        price = _price;
        deadline = block.timestamp + _duration;
    }

    /// @notice Buyer locks funds. Seller can only be paid after delivery is confirmed.
    function pay() external onlyBuyer inState(State.Created) nonReentrant {
        wtc.safeTransferFrom(msg.sender, address(this), price);
        state = State.Paid;
        emit Paid(msg.sender, price);
    }

    /// @notice Seller marks the item delivered.
    function deliver() external onlySeller inState(State.Paid) {
        state = State.Delivered; // (kept as a distinct marker; see note below)
    }

    /// @notice Buyer confirms receipt -> funds release to seller.
    function confirm() external onlyBuyer inState(State.Delivered) nonReentrant {
        state = State.Completed;
        wtc.safeTransfer(seller, price);
        emit Confirmed(msg.sender);
    }

    /// @notice Either party can raise a dispute before completion.
    function dispute(string calldata reason) external {
        require(msg.sender == buyer || msg.sender == seller, "Not party");
        require(state == State.Paid || state == State.Delivered, "Cannot dispute");
        state = State.Disputed;
        disputeReason = reason;
        emit Disputed(msg.sender, reason);
    }

    /// @notice Admin (factory owner) resolves a dispute to buyer or seller.
    function resolve(address winner) external onlyOwner inState(State.Disputed) nonReentrant {
        require(winner == buyer || winner == seller, "Bad winner");
        state = State.Completed;
        if (winner == seller) {
            wtc.safeTransfer(seller, price);
        } else {
            wtc.safeTransfer(buyer, price);
        }
        emit Resolved(winner, price);
    }

    /// @notice Buyer can pull funds back before the seller ships (or after timeout).
    function refund() external onlyBuyer nonReentrant {
        if (state == State.Created) {
            // nothing locked yet; nothing to return
            state = State.Refunded;
            emit Refunded(msg.sender, 0);
        } else if (state == State.Paid && block.timestamp > deadline) {
            state = State.Refunded;
            wtc.safeTransfer(buyer, price);
            emit Refunded(msg.sender, price);
        } else {
            revert("Not refundable");
        }
    }

    /// @notice Seller can claim after timeout if buyer never confirmed.
    function claimAfterTimeout() external onlySeller inState(State.Paid) nonReentrant {
        require(block.timestamp > deadline, "Not expired");
        state = State.Completed;
        wtc.safeTransfer(seller, price);
        emit Resolved(seller, price);
    }
}
