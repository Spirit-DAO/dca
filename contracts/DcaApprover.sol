// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <=0.8.25;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

import 'contracts/Libraries/TransferHelper.sol';

struct Order {
    address user;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 amountOutMin;
    uint256 period;
    uint256 lastExecution;
    uint256 totalExecutions;
    uint256 totalAmountIn;
    uint256 totalAmountOut;
    uint256 createdAt;
    bool stopped;
    address approver;
	bytes32	taskId;
}

interface ISilverDCA {
    function ordersById(uint256) external returns (Order memory);
}

contract SilverDcaApprover is Ownable {
	uint256 public id;
    address public dca;
    address public user;
    address public tokenIn;

    //	Here hardcode some values to avoid any manipulation of the contract
	constructor(uint256 _id, address _user, address _tokenIn) Ownable(msg.sender) {
		id = _id;
        dca = msg.sender;
        user = _user;
        tokenIn = _tokenIn;
	}

	/**
	 * @dev Transfer the tokenIn to the DCA contract (for the order execution)
	 */
    function executeOrder() public onlyDCA {
        Order memory order = ISilverDCA(dca).ordersById(id);

		require(block.timestamp - order.lastExecution >= order.period, 'Period not elapsed.');
        require(!order.stopped, 'Order is stopped');

        TransferHelper.safeTransferFrom(tokenIn, user, dca, order.amountIn);
    }

	/**
	 * @dev Transfer the tokenIn to the DCA contract (for gelato's fees)
	 * @param feesAmount The amount of fees to transfer (in tokenIn)
	 */
	function transferGelatoFees(uint256 feesAmount) public onlyDCA {
        Order memory order = ISilverDCA(dca).ordersById(id);

		require(block.timestamp - order.lastExecution >= order.period, 'Period not elapsed.');
        require(!order.stopped, 'Order is stopped');

        TransferHelper.safeTransferFrom(tokenIn, user, dca, feesAmount);
    }


	// Modifiers 

	modifier onlyDCA() { // G-04
		require(msg.sender == dca, 'Not authorized');
		_;
	}
}