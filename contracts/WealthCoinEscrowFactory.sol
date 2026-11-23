// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./WealthCoinEscrow.sol";

/// @title WealthCoinEscrowFactory
/// @notice Deploys one WealthCoinEscrow per sale, tracks them, and collects
///         the marketplace fee in WTC.
contract WealthCoinEscrowFactory is Ownable2Step {
    using SafeERC20 for IERC20;

    struct Sale {
        address escrow;
        address buyer;
        address seller;
        uint256 priceInWTC;
        uint256 createdAt;
    }

    IERC20 public immutable wtc;

    uint256 public constant MAX_FEE_BPS = 500; // 5% hard ceiling
    uint256 public constant MIN_PAYMENT_WINDOW = 1 hours;
    uint256 public constant MIN_DELIVERY_WINDOW = 1 days;

    uint256 public feeBps;
    address public feeRecipient;
    address public resolver;

    uint256 public defaultPaymentWindow = 3 days;
    uint256 public defaultDeliveryWindow = 14 days;

    /// @notice Fees collected by escrows, not yet swept.
    uint256 public accruedFees;

    Sale[] public sales;
    mapping(address => uint256[]) private _salesByBuyer;
    mapping(address => uint256[]) private _salesBySeller;
    mapping(address => bool) public isEscrow;

    event EscrowCreated(
        uint256 indexed saleId,
        address indexed escrow,
        address indexed buyer,
        address seller,
        uint256 priceInWTC
    );
    event FeeUpdated(uint256 feeBps);
    event FeeRecipientUpdated(address recipient);
    event ResolverUpdated(address resolver);
    event WindowsUpdated(uint256 paymentWindow, uint256 deliveryWindow);
    event FeesSwept(address indexed to, uint256 amount);

    error FeeTooHigh();
    error ZeroAddress();
    error ZeroPrice();
    error SameParties();
    error InvalidWindow();
    error NotEscrow(); // CHANGED: was reusing ZeroAddress

    constructor(
        address _wtc,
        address _feeRecipient,
        address _resolver,
        uint256 _feeBps
    ) Ownable(msg.sender) {
        if (_wtc == address(0) || _feeRecipient == address(0) || _resolver == address(0))
            revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        wtc = IERC20(_wtc);
        feeRecipient = _feeRecipient;
        resolver = _resolver;
        feeBps = _feeBps;
    }

    /// @notice Create a new escrow for a sale. Anyone can call; the buyer funds it later.
    function createEscrow(
        address buyer,
        address seller,
        uint256 priceInWTC
    ) external returns (address escrow) {
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (buyer == seller) revert SameParties();
        if (priceInWTC == 0) revert ZeroPrice();
        // CHANGED: removed the unreachable resolver == address(0) check.
        // setResolver() and the constructor already block zero, so it could
        // never fire. The escrow constructor still checks it as a safety net.

        escrow = address(
            new WealthCoinEscrow(
                address(wtc),
                buyer,
                seller,
                address(this),
                resolver,
                priceInWTC,
                feeBps,
                block.timestamp + defaultPaymentWindow,
                defaultDeliveryWindow
            )
        );

        uint256 saleId = sales.length;
        sales.push(Sale({
            escrow: escrow,
            buyer: buyer,
            seller: seller,
            priceInWTC: priceInWTC,
            createdAt: block.timestamp
        }));

        _salesByBuyer[buyer].push(saleId);
        _salesBySeller[seller].push(saleId);
        isEscrow[escrow] = true;

        emit EscrowCreated(saleId, escrow, buyer, seller, priceInWTC);
    }

    function totalSales() external view returns (uint256) {
        return sales.length;
    }

    function salesByBuyer(address buyer) external view returns (uint256[] memory) {
        return _salesByBuyer[buyer];
    }

    function salesBySeller(address seller) external view returns (uint256[] memory) {
        return _salesBySeller[seller];
    }

    /// @notice Sweeps only the fees escrows have sent here, never other WTC
    ///         that may land on this contract.
    function sweepFees() external onlyOwner {
        uint256 amount = accruedFees;
        if (amount == 0) return;
        accruedFees = 0;
        wtc.safeTransfer(feeRecipient, amount);
        emit FeesSwept(feeRecipient, amount);
    }

    /// @notice Called by an escrow when it pays its fee. Keeps the sweep honest.
    function notifyFeeReceived(uint256 amount) external {
        if (!isEscrow[msg.sender]) revert NotEscrow(); // CHANGED
        accruedFees += amount;
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = _feeBps;
        emit FeeUpdated(_feeBps);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    function setResolver(address _resolver) external onlyOwner {
        if (_resolver == address(0)) revert ZeroAddress();
        resolver = _resolver;
        emit ResolverUpdated(_resolver);
    }

    function setDefaultWindows(uint256 _paymentWindow, uint256 _deliveryWindow) external onlyOwner {
        if (_paymentWindow < MIN_PAYMENT_WINDOW || _deliveryWindow < MIN_DELIVERY_WINDOW)
            revert InvalidWindow();
        defaultPaymentWindow = _paymentWindow;
        defaultDeliveryWindow = _deliveryWindow;
        emit WindowsUpdated(_paymentWindow, _deliveryWindow);
    }
}
