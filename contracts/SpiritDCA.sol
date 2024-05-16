// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Utils} from "contracts/Libraries/Utils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import 'contracts/DcaApprover.sol';
import 'contracts/Integrations/Gelato/AutomateTaskCreator.sol';

import "@openzeppelin/contracts/utils/Strings.sol";
import {IOpsProxy} from "contracts/Interfaces/IOpsProxy.sol";

interface IProxyParaswap {
	function simpleSwap(Utils.SimpleData memory data) external payable returns (uint256);
	function multiSwap(Utils.SellData memory data) external payable returns (uint256);
	function megaSwap(Utils.MegaSwapSellData memory data) external payable returns (uint256);
}

contract SpiritSwapDCA is Ownable {
	IProxyParaswap public proxy;
	IERC20 public usdc;
	IERC20 public tresory;

	constructor(address _proxy, address _automate, address _tresory, address _usdc) Ownable(msg.sender) {
		proxy = IProxyParaswap(payable(_proxy));
		tresory = IERC20(_tresory);
		usdc = IERC20(_usdc);
	}

	function test() view public returns (bytes memory) {
		bytes memory execData = abi.encode(
			address(this),
			0,
			"0x26F38E36d2Ba44eE5E7E35655be72852e49Ea04c",			
			"0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83",
			"0x5Cc61A78F164885776AA610fb0FE1257df78E59B",			
			Strings.toString(18),
			Strings.toString(18),
			Strings.toString(990000000000000000),
			"250",
			"spiritswap",
			"false",
			"15"
		);
		return execData;
	}
}
/*contract SpiritSwapDCA is Ownable, AutomateTaskCreator {
	IProxyParaswap public proxy;
	IERC20 public tresory;
	IERC20 public usdc;
	
	uint256 public ordersCount;
	mapping(uint256 => Order) public ordersById;
	mapping(address => uint256[]) public idByAddress;

	struct argParaswap {
		Utils.SimpleData simpleData;
		Utils.SellData sellData;
		Utils.MegaSwapSellData megaSwapSellData;
	}

	event OrderCreated(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);
	event OrderEdited(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);
	event OrderStopped(address indexed user, uint256 indexed id);
	event OrderRestarted(address indexed user, uint256 indexed id);
	event OrderExecuted(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);
	event OrderFailed(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);

	// Event for GELATO
	event CounterTaskCreated(bytes32 id);
	event CounterTaskCancelled(bytes32 id);
	event FeesCheck(uint256 fees, address token);

	constructor(address _proxy, address _automate, address _tresory, address _usdc) Ownable(msg.sender) AutomateTaskCreator(_automate) {
		proxy = IProxyParaswap(payable(_proxy));
		tresory = IERC20(_tresory);
		usdc = IERC20(_usdc);
	}

	function isSimpleDataEmpty(Utils.SimpleData memory _simpleData) pure private returns (bool) {
		return _simpleData.fromToken == address(0) || _simpleData.toToken == address(0) || _simpleData.fromAmount == 0 || _simpleData.toAmount == 0 || _simpleData.beneficiary == address(0);
	}

	function isSellDataEmpty(Utils.SellData memory _sellData) pure private returns (bool) {
		return _sellData.fromToken == address(0) || _sellData.fromAmount == 0 || _sellData.toAmount == 0 || _sellData.beneficiary == address(0) || _sellData.path.length == 0;
	}

	function isMegaSwapSellDataEmpty(Utils.MegaSwapSellData memory _megaSwapSellData) pure private returns (bool) {
		return _megaSwapSellData.fromToken == address(0) || _megaSwapSellData.fromAmount == 0 || _megaSwapSellData.toAmount == 0 || _megaSwapSellData.beneficiary == address(0) || _megaSwapSellData.path.length == 0;
	}

	function _executeOrder(uint id, argParaswap memory argProxy) private {
		require(!isSimpleDataEmpty(argProxy.simpleData) || !isSellDataEmpty(argProxy.sellData) || !isMegaSwapSellDataEmpty(argProxy.megaSwapSellData), "Invalid argParaswap.");

		address user = ordersById[id].user;
		IERC20 tokenIn = IERC20(ordersById[id].tokenIn);
		IERC20 tokenOut = IERC20(ordersById[id].tokenOut);
		uint256	fees = ordersById[id].amountIn / 100;

		if (!isSimpleDataEmpty(argProxy.simpleData)) {
			argProxy.simpleData.beneficiary = payable(address(user));
			argProxy.simpleData.toToken = ordersById[id].tokenOut;
			argProxy.simpleData.fromToken = ordersById[id].tokenIn;
			argProxy.simpleData.fromAmount = ordersById[id].amountIn - fees;
		} else if (!isSellDataEmpty(argProxy.sellData)) {
			argProxy.sellData.beneficiary = payable(address(user));
			argProxy.sellData.fromToken = ordersById[id].tokenIn;
			argProxy.sellData.fromAmount = ordersById[id].amountIn - fees;
		} else if (!isMegaSwapSellDataEmpty(argProxy.megaSwapSellData)) {
			argProxy.megaSwapSellData.beneficiary = payable(address(user));
			argProxy.megaSwapSellData.fromToken = ordersById[id].tokenIn;
			argProxy.megaSwapSellData.fromAmount = ordersById[id].amountIn - fees;
		}

		uint256 balanceBefore = tokenOut.balanceOf(user);
		ordersById[id].totalExecutions += 1;
		ordersById[id].totalAmountIn += ordersById[id].amountIn;
        SpiritDcaApprover(ordersById[id].approver).executeOrder();
		ordersById[id].lastExecution = block.timestamp;
		
		tokenIn.transfer(address(tresory), fees);
		tokenIn.approve(address(proxy), ordersById[id].amountIn - fees);
		if (!isSimpleDataEmpty(argProxy.simpleData)) {
			proxy.simpleSwap(argProxy.simpleData);
		} else if (!isSellDataEmpty(argProxy.sellData)) {
			proxy.multiSwap(argProxy.sellData);
		} else if (!isMegaSwapSellDataEmpty(argProxy.megaSwapSellData)) {
			proxy.megaSwap(argProxy.megaSwapSellData);
		}
		
		uint256 balanceAfter = tokenOut.balanceOf(user);
		require(balanceAfter - balanceBefore >= ordersById[id].amountOutMin, 'Too little received.');
		ordersById[id].totalAmountOut += balanceAfter - balanceBefore;

		emit OrderExecuted(user, id, ordersById[id].tokenIn, ordersById[id].tokenOut, ordersById[id].amountIn - fees, ordersById[id].amountOutMin, ordersById[id].period);
	}
	
	function executeOrder(uint256 id, argParaswap memory argProxy) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].stopped == false, 'Order is stopped.');
		require(block.timestamp - ordersById[id].lastExecution >= ordersById[id].period, 'Period not elapsed.');
		require(ERC20(ordersById[id].tokenIn).balanceOf(ordersById[id].user) >= ordersById[id].amountIn, 'Not enough balance.');

		_executeOrder(id, argProxy);

		//(uint256 fee, address feeToken) = _getFeeDetails();

        //_transfer(fee, feeToken);
		//emit FeesCheck(fee, feeToken);
	}

	function getOrdersCountTotal() public view returns (uint256) {
		return ordersCount;
	}

    function getOrdersCountByAddress(address user) public view returns (uint256) {
        return idByAddress[user].length;
    }

    function getOrdersByIndex(address user, uint256 index) public view returns (Order memory, uint256 id) {
        return (ordersById[idByAddress[user][index]], idByAddress[user][index]);
    }

    function getApproveBytecode(uint256 _id, address _user, address _tokenIn) public pure returns (bytes memory) {
        bytes memory bytecode = type(SpiritDcaApprover).creationCode;

        return abi.encodePacked(bytecode, abi.encode(_id, _user, _tokenIn));
    }

    function getApproveAddress(address _user, address _tokenIn) public view returns (address) {
        uint _id = ordersCount;
        bytes memory bytecode = getApproveBytecode(_id, _user, _tokenIn);

        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), _id, keccak256(bytecode))
        );

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint(hash)));
    }
	
	function createTask(uint256 id) public {
		require(ordersById[id].taskId == bytes32(""), 'Task already created.');

		bytes memory execData = abi.encode(
			address(this),													//dca
			id,																//id
			ordersById[id].user,											//userAddress						
			ordersById[id].tokenIn,											//srcToken
			ordersById[id].tokenOut,										//destToken
			Strings.toString(ERC20(ordersById[id].tokenIn).decimals()),		//srcDecimals
			Strings.toString(ERC20(ordersById[id].tokenOut).decimals()),	//destDecimals
			Strings.toString((ordersById[id].amountIn / 100) * 99),			//amount
			"250",															//network
			"spiritswap",													//partner
			"false",														//otherExchangePrices
			"15"															//maxImpact
		);

		ModuleData memory moduleData = ModuleData({
			modules: new Module[](3),
			args: new bytes[](3)
		});

		moduleData.modules[0] = Module.PROXY;
		moduleData.modules[1] = Module.WEB3_FUNCTION;
		moduleData.modules[2] = Module.TRIGGER;
	
		moduleData.args[0] = _proxyModuleArg();
		moduleData.args[1] = _web3FunctionModuleArg(
			"QmVxYA3Z6NGhps7Snd8qPjomjCuMtdABqvA9Ahop2Edee3",
			execData
		);
		moduleData.args[2] = _timeTriggerModuleArg(
			uint128(ordersById[id].lastExecution), 
			uint128(ordersById[id].period * 10)//Milliseconds
		);

		bytes32 taskId = _createTask(address(this), execData, moduleData, address(0));
	
		ordersById[id].taskId = taskId;
		
		emit CounterTaskCreated(taskId);
	}

	function cancelTask(uint256 id) public {
        require(ordersById[id].taskId != bytes32(""), "Task not started");
		bytes32 taskId = ordersById[id].taskId;
		ordersById[id].taskId = bytes32("");

        _cancelTask(taskId);

		emit CounterTaskCancelled(taskId);
    }

	function createOrder(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period, argParaswap memory argProxy) public {
		require(period > 0, 'Period must be greater than 0.');
		require(amountIn > 0, 'AmountIn must be greater than 0.');
		require(tokenIn != tokenOut, 'TokenOut must be different.');
		require(tokenIn != address(0), 'Invalid tokenIn.');
		require(tokenOut != address(0), 'Invalid tokenOut.');

        address approver = address(new SpiritDcaApprover{salt: bytes32(ordersCount)}(ordersCount, msg.sender, tokenIn));
		Order memory order = Order(msg.sender, tokenIn, tokenOut, amountIn, amountOutMin, period, 0, 0, 0, 0, block.timestamp, false, approver, 0);
		ordersById[ordersCount] = order;
		idByAddress[msg.sender].push(ordersCount);
		ordersCount++;

		_executeOrder(getOrdersCountTotal() - 1, argProxy);
		createTask(getOrdersCountTotal() - 1);

		emit OrderCreated(msg.sender, getOrdersCountTotal() - 1, tokenIn, tokenOut, amountIn, amountOutMin, period);
	}

	function editOrder(uint256 id, uint256 amountIn, uint256 amountOutMin, uint256 period, argParaswap memory argProxy) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].user == msg.sender, 'Order does not belong to user.');
		require(period > 0, 'Period must be greater than 0.');
		require(amountIn > 0, 'AmountIn must be greater than 0.');

		ordersById[id].amountIn = amountIn;
		ordersById[id].amountOutMin = amountOutMin;
		if (ordersById[id].period != period)
		{
			ordersById[id].period = period;
			cancelTask(id);
			if (block.timestamp - ordersById[id].lastExecution >= ordersById[id].period) 
			{
				_executeOrder(id, argProxy);
			}
			createTask(id);
		}

		emit OrderEdited(msg.sender, id, ordersById[id].tokenIn, ordersById[id].tokenOut, amountIn, amountOutMin, period);
	}

	function stopOrder(uint256 id) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].user == msg.sender, 'Order does not belong to user.');
		require(ordersById[id].stopped == false, 'Order is already stopped.');

		ordersById[id].stopped = true;
		cancelTask(id);//Before or after struct value change?

		emit OrderStopped(msg.sender, id);
	}
	
	function restartOrder(uint256 id, argParaswap memory argProxy) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].user == msg.sender, 'Order does not belong to user.');
		require(ordersById[id].stopped == true, 'Order is not stopped.');

		ordersById[id].stopped = false;
		if (block.timestamp - ordersById[id].lastExecution >= ordersById[id].period) {
			_executeOrder(id, argProxy);
		}
		createTask(id);

		emit OrderRestarted(msg.sender, id);
	}

	function editUSDC(address _usdc) public onlyOwner {
		usdc = IERC20(_usdc);
	}

	function editTresory(address _tresory) public onlyOwner {
		tresory = IERC20(_tresory);
	}
}*/

//Interdire cancelOrder aux gens