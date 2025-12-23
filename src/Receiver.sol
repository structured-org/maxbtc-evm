// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28;

contract Receiver {
    address public publisher;
    uint256 private er;
    uint256 private ts;
    int256 private aum;
    uint8 private aumDecimals;

    event PublisherUpdated(
        address indexed oldPublisher,
        address indexed newPublisher
    );

    event ValuesPublished(uint256 er, uint256 ts);
    event AumPublished(int256 aum, uint8 decimals);

    error NotPublisher();

    constructor(address _publisher) {
        require(_publisher != address(0), "zero publisher");
        publisher = _publisher;
    }

    modifier onlyPublisher() {
        _onlyPublisher();
        _;
    }

    function _onlyPublisher() internal view {
        if (msg.sender != publisher) revert NotPublisher();
    }

    function setPublisher(address newPublisher) external onlyPublisher {
        require(newPublisher != address(0), "zero addr");
        emit PublisherUpdated(publisher, newPublisher);
        publisher = newPublisher;
    }

    function publish(uint256 newEr, uint256 newTs) external onlyPublisher {
        er = newEr;
        ts = newTs;
        emit ValuesPublished(newEr, newTs);
    }

    function publishAum(int256 newAum, uint8 decimals_) external onlyPublisher {
        aum = newAum;
        aumDecimals = decimals_;
        emit AumPublished(newAum, decimals_);
    }

    function getLatest() external view returns (uint256 _er, uint256 _ts) {
        return (er, ts);
    }

    function getTwaer() external view returns (uint256 _er, uint256 _ts) {
        return (er, ts);
    }

    function getAum() external view returns (int256 _aum, uint8 decimals_) {
        return (aum, aumDecimals);
    }
}
