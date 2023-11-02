// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

contract IglooSubject is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using AddressUpgradeable for address payable;

    address payable public protocolFeeDestination;
    uint256 public protocolFeePercent;
    uint256 public subjectFeePercent;

    IERC20 public membershipToken;
    uint256 public membershipWeight;

    uint256 private constant BASE_DIVIDER = 100;

    mapping(address => mapping(address => uint256)) public keysBalance;
    mapping(address => uint256) public keysSupply;

    event SetProtocolFeeDestination(address indexed destination);
    event SetProtocolFeePercent(uint256 percent);
    event SetSubjectFeePercent(uint256 percent);
    event SetMembershipToken(address indexed token);
    event SetMembershipWeight(uint256 weight);

    event Trade(
        address indexed trader,
        address indexed subject,
        bool indexed isBuy,
        uint256 amount,
        uint256 price,
        uint256 protocolFee,
        uint256 subjectFee,
        uint256 supply
    );

    function initialize(
        address payable _protocolFeeDestination,
        uint256 _protocolFeePercent,
        uint256 _subjectFeePercent
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        protocolFeeDestination = _protocolFeeDestination;
        protocolFeePercent = _protocolFeePercent;
        subjectFeePercent = _subjectFeePercent;

        emit SetProtocolFeeDestination(_protocolFeeDestination);
        emit SetProtocolFeePercent(_protocolFeePercent);
        emit SetSubjectFeePercent(_subjectFeePercent);
    }

    function setProtocolFeeDestination(address payable _feeDestination) public onlyOwner {
        protocolFeeDestination = _feeDestination;
        emit SetProtocolFeeDestination(_feeDestination);
    }

    function setProtocolFeePercent(uint256 _feePercent) public onlyOwner {
        protocolFeePercent = _feePercent;
        emit SetProtocolFeePercent(_feePercent);
    }

    function setSubjectFeePercent(uint256 _feePercent) public onlyOwner {
        subjectFeePercent = _feePercent;
        emit SetSubjectFeePercent(_feePercent);
    }

    function setMembershipToken(address _token) public onlyOwner {
        membershipToken = IERC20(_token);
        emit SetMembershipToken(_token);
    }

    function setMembershipWeight(uint256 _weight) public onlyOwner {
        require(_weight <= protocolFeePercent, "Weight cannot exceed protocol fee percent");
        membershipWeight = _weight;
        emit SetMembershipWeight(_weight);
    }

    function calculateAdditionalFee(uint256 price, address subject) public view returns (uint256) {
        if (address(membershipToken) == address(0)) {
            return 0;
        }

        uint256 memberBalance = membershipToken.balanceOf(subject);
        uint256 feeIncrease = (((price * membershipWeight) / 1 ether) * memberBalance) / 1 ether;
        uint256 maxAdditionalFee = (price * protocolFeePercent) / 1 ether;

        return feeIncrease < maxAdditionalFee ? feeIncrease : maxAdditionalFee;
    }

    function getPrice(uint256 supply, uint256 amount) public pure returns (uint256) {
        uint256 sum1 = ((supply * (supply + 1)) * (2 * supply + 1)) / 6;
        uint256 sum2 = (((supply + amount) * (supply + 1 + amount)) * (2 * (supply + amount) + 1)) / 6;
        uint256 summation = sum2 - sum1;
        return (summation * 1 ether) / BASE_DIVIDER;
    }

    function getBuyPrice(address subject, uint256 amount) public view returns (uint256) {
        return getPrice(keysSupply[subject], amount);
    }

    function getSellPrice(address subject, uint256 amount) public view returns (uint256) {
        return getPrice(keysSupply[subject] - amount, amount);
    }

    function getBuyPriceAfterFee(address subject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(subject, amount);
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether;
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        return price + protocolFee + subjectFee;
    }

    function getSellPriceAfterFee(address subject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(subject, amount);
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether;
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        return price - protocolFee - subjectFee;
    }

    function executeTrade(address subject, uint256 amount, uint256 price, bool isBuy) private nonReentrant {
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        uint256 additionalFee = calculateAdditionalFee(price, subject);
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether - additionalFee;

        uint256 supply = keysSupply[subject];

        if (isBuy) {
            require(msg.value >= price + protocolFee + subjectFee + additionalFee, "Insufficient payment");
            keysBalance[subject][msg.sender] += amount;
            supply += amount;
            keysSupply[subject] = supply;
            protocolFeeDestination.sendValue(protocolFee);
            payable(subject).sendValue(subjectFee + additionalFee);
            if (msg.value > price + protocolFee + subjectFee + additionalFee) {
                uint256 refund = msg.value - price - protocolFee - subjectFee - additionalFee;
                payable(msg.sender).sendValue(refund);
            }
        } else {
            require(keysBalance[subject][msg.sender] >= amount, "Insufficient keys");
            keysBalance[subject][msg.sender] -= amount;
            supply -= amount;
            keysSupply[subject] = supply;
            uint256 netAmount = price - protocolFee - subjectFee - additionalFee;
            payable(msg.sender).sendValue(netAmount);
            protocolFeeDestination.sendValue(protocolFee);
            payable(subject).sendValue(subjectFee + additionalFee);
        }

        emit Trade(msg.sender, subject, isBuy, amount, price, protocolFee, subjectFee + additionalFee, supply);
    }

    function buyKeys(address subject, uint256 amount) public payable {
        uint256 price = getBuyPrice(subject, amount);
        executeTrade(subject, amount, price, true);
    }

    function sellKeys(address subject, uint256 amount) public {
        uint256 price = getSellPrice(subject, amount);
        executeTrade(subject, amount, price, false);
    }
}
