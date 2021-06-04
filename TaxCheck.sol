// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./TransferHelper.sol";


contract TaxCheck {

    address public presaleTokenAddr;
    address public presale;
    uint256 public tokenBalance;
    
    constructor(address _presaleTokenAddr, address _presale, uint256 _tokenBalance) public {
        presaleTokenAddr = _presaleTokenAddr;
        presale = _presale;
        tokenBalance = _tokenBalance;
        TransferHelper.safeApprove(presaleTokenAddr, presale, tokenBalance);
    }

    function transferBack() public {
        TransferHelper.safeTransfer(presaleTokenAddr, presale, tokenBalance);
    }
}