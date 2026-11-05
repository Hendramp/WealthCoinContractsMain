// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./WealthCoinEscrow.sol";

/// @title WealthCoin Escrow Factory
/// @notice Deploys one escrow per sale and tracks them all.
contract WealthCoinEscrowFactory is Ownable, Pausable {
    IERC20 public immutable wtc;
    uint256 public immutable feeBps;          // e.g. 250 = 2.5%
    uint256 public defaultDuration;           // seconds until auto-release

    address[] public escrows;
    mapping(address => bool) public isEscrow;
    mapping(address => address[]) public escrowsBySeller;

    event EscrowCreated(
        address indexed escrow,
        address indexed seller,
        address indexed buyer,
        uint256 priceWtc,
        uint256 feeWtc
    );

    constructor(address _wtc, uint256 _feeBps, uint256 _defaultDuration)
        Ownable(msg.sender)
    {
        require(_wtc != address(0), "Bad token");
        require(_feeBps <= 10_000, "Fee too high");
        wtc = IERC20(_wtc);
        feeBps = _feeBps;
        defaultDuration = _defaultDuration;
    }

    function createEscrow(address buyer, uint256 priceWtc) external whenNotPaused returns (address) {
        require(buyer != address(0), "Bad buyer");
        require(priceWtc > 0, "Price zero");

        WealthCoinEscrow escrow = new WealthCoinEscrow(
            address(wtc),
            buyer,
            msg.sender,          // seller = caller
            priceWtc,
            defaultDuration
        );

        escrows.push(address(escrow));
        isEscrow[address(escrow)] = true;
        escrowsBySeller[msg.sender].push(address(escrow));

        uint256 feeWtc = (priceWtc * feeBps) / 10_000;
        emit EscrowCreated(address(escrow), msg.sender, buyer, priceWtc, feeWtc);
        return address(escrow);
    }

    function setDefaultDuration(uint256 _duration) external onlyOwner {
        defaultDuration = _duration;
    }

    function escrowCount() external view returns (uint256) {
        return escrows.length;
    }
}
