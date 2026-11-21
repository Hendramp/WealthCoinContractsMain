// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal interface to the factory's fee accounting. Declared here
///         instead of importing the factory, which would be a circular import.
interface IFeeSink {
    function notifyFeeReceived(uint256 amount) external;
}

/// @title WealthCoinEscrow
/// @notice Single-sale escrow, WTC only. Buyer funds it, seller delivers, buyer
///         confirms (or the delivery window lapses and funds auto-release to the
///         seller). The factory's resolver can settle disputes.
contract WealthCoinEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        Created,    // deployed, awaiting buyer payment
        Paid,       // buyer funded, seller has not marked delivery
        Delivered,  // seller marked delivery, awaiting buyer confirmation
        Completed,  // funds released to seller
        Refunded,   // funds returned to buyer
        Disputed    // frozen, awaiting resolver
    }

    uint256 public constant MAX_FEE_BPS = 500; // must match the factory

    IERC20 public immutable wtc;
    address public immutable buyer;
    address public immutable seller;
    address public immutable factory;
    address public immutable resolver;

    uint256 public immutable priceInWTC;
    uint256 public immutable feeInWTC;
    uint256 public immutable feeBps;
    uint256 public immutable paymentDeadline;
    uint256 public immutable deliveryWindow;

    State public state;
    uint256 public deliveredAt;

    event Funded(address indexed buyer, uint256 amount);
    event Delivered(address indexed seller, uint256 at);
    event Completed(address indexed seller, uint256 sellerAmount, uint256 feeAmount);
    event Refunded(address indexed buyer, uint256 amount);
    event Disputed(address indexed by);
    event Resolved(address indexed to, uint256 amount, bool toSeller);

    error WrongState(State current);
    error NotBuyer();
    error NotSeller();
    error NotParty();
    error NotResolver();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error WindowNotElapsed();
    error ZeroAddress();
    error ZeroPrice();
    error FeeTooHigh();
    error InvalidWindow();

    modifier onlyBuyer() {
        if (msg.sender != buyer) revert NotBuyer();
        _;
    }

    modifier onlySeller() {
        if (msg.sender != seller) revert NotSeller();
        _;
    }

    modifier inState(State s) {
        if (state != s) revert WrongState(state);
        _;
    }

    constructor(
        address _wtc,
        address _buyer,
        address _seller,
        address _factory,
        address _resolver,
        uint256 _priceInWTC,
        uint256 _feeBps,
        uint256 _paymentDeadline,
        uint256 _deliveryWindow
    ) {
        if (_wtc == address(0) || _buyer == address(0) || _seller == address(0)
            || _factory == address(0) || _resolver == address(0)) revert ZeroAddress();
        if (_buyer == _seller) revert NotParty();
        if (_priceInWTC == 0) revert ZeroPrice();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (_deliveryWindow == 0) revert InvalidWindow();

        wtc = IERC20(_wtc);
        buyer = _buyer;
        seller = _seller;
        factory = _factory;
        resolver = _resolver;
        priceInWTC = _priceInWTC;
        feeBps = _feeBps;
        feeInWTC = (_priceInWTC * _feeBps) / 10_000;
        paymentDeadline = _paymentDeadline;
        deliveryWindow = _deliveryWindow;
        state = State.Created;
    }

    /// @notice Buyer funds the escrow with `priceInWTC`. Fee is held back on release.
    function fund() external onlyBuyer inState(State.Created) nonReentrant {
        if (block.timestamp > paymentDeadline) revert DeadlinePassed();
        state = State.Paid;
        wtc.safeTransferFrom(msg.sender, address(this), priceInWTC);
        emit Funded(msg.sender, priceInWTC);
    }

    /// @notice Seller marks the goods as shipped or handed over. Starts the buyer's window.
    function deliver() external onlySeller inState(State.Paid) {
        state = State.Delivered;
        deliveredAt = block.timestamp;
        emit Delivered(msg.sender, block.timestamp);
    }

    /// @notice Buyer accepts delivery, releasing funds to the seller minus the fee.
    function confirmDelivery() external onlyBuyer inState(State.Delivered) nonReentrant {
        _release();
    }

    /// @notice Anyone can push funds to the seller once the delivery window lapses.
    ///         Buyer silence is not a veto.
    function claimAfterWindow() external inState(State.Delivered) nonReentrant {
        if (block.timestamp < deliveredAt + deliveryWindow) revert WindowNotElapsed();
        _release();
    }

    /// @notice Buyer recovers funds if the seller never marked delivery and the
    ///         payment deadline plus the delivery window has passed. Cannot run
    ///         after delivery — use raiseDispute() for that case.
    function claimAfterNoDelivery() external onlyBuyer inState(State.Paid) nonReentrant {
        if (block.timestamp <= paymentDeadline + deliveryWindow) revert DeadlineNotPassed();
        state = State.Refunded;
        wtc.safeTransfer(buyer, priceInWTC);
        emit Refunded(buyer, priceInWTC);
    }

    /// @notice Either party can freeze the escrow for resolver review, before or
    ///         after the seller marks delivery.
    function raiseDispute() external nonReentrant {
        if (state != State.Paid && state != State.Delivered) revert WrongState(state);
        if (msg.sender != buyer && msg.sender != seller) revert NotParty();
        state = State.Disputed;
        emit Disputed(msg.sender);
    }

    /// @notice Resolver settles a dispute. Terminal.
    function resolve(bool toSeller) external nonReentrant {
        if (msg.sender != resolver) revert NotResolver();
        if (state != State.Disputed) revert WrongState(state);

        if (toSeller) {
            state = State.Completed;
            _payout();
            emit Resolved(seller, priceInWTC - feeInWTC, true);
        } else {
            state = State.Refunded;
            wtc.safeTransfer(buyer, priceInWTC);
            emit Resolved(buyer, priceInWTC, false);
        }
    }

    function _release() internal {
        state = State.Completed;
        _payout();
        emit Completed(seller, priceInWTC - feeInWTC, feeInWTC);
    }

    function _payout() internal {
        wtc.safeTransfer(seller, priceInWTC - feeInWTC);
        if (feeInWTC > 0) {
            wtc.safeTransfer(factory, feeInWTC);
            IFeeSink(factory).notifyFeeReceived(feeInWTC);
        }
    }
}
