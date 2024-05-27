// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Utils} from "contracts/Libraries/Utils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import 'contracts/DcaApprover.sol';
import "@openzeppelin/contracts/utils/Strings.sol";

import 'contracts/Integrations/Gelato/AutomateTaskCreator.sol';
import {IOpsProxy} from "contracts/Interfaces/IOpsProxy.sol";

interface IProxyParaswap {
	function simpleSwap(Utils.SimpleData memory data) external payable returns (uint256);
	function multiSwap(Utils.SellData memory data) external payable returns (uint256);
	function megaSwap(Utils.MegaSwapSellData memory data) external payable returns (uint256);
}

contract SpiritSwapDCA is AutomateTaskCreator, Ownable {
	IProxyParaswap public proxy;
	IERC20 public tresory;
	
	uint256 public ordersCount;
	mapping(uint256 => Order) public ordersById;
	mapping(address => uint256[]) public idByAddress;

	struct paraswapArgs {
		Utils.SimpleData simpleData;
		Utils.SellData sellData;
		Utils.MegaSwapSellData megaSwapSellData;
	}

	string private scriptCID = "QmatgdMrv1dqwKuhxFi6stHctQUGrb8GQg6NBs68mxCZhY";

	// Event for Orders
	event OrderCreated(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);
	event OrderEdited(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);
	event OrderStopped(address indexed user, uint256 indexed id);
	event OrderRestarted(address indexed user, uint256 indexed id);
	event OrderExecuted(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);

	// Event for GELATO
	event GelatoTaskCreated(bytes32 id);
	event GelatoTaskCancelled(bytes32 id);
	event GelatoFeesCheck(uint256 fees, address token);

	// Event for Misc
	event EditedTresory(address usdc);
	event WithdrawnFees(address tresory, uint256 amount);


	constructor(address _proxy, address _automate, address _tresory) AutomateTaskCreator(_automate) Ownable(msg.sender) {
		proxy = IProxyParaswap(payable(_proxy));
		tresory = IERC20(_tresory);
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

	function _executeOrder(uint id, paraswapArgs memory dcaArgs) private {
		require(!isSimpleDataEmpty(dcaArgs.simpleData) || !isSellDataEmpty(dcaArgs.sellData) || !isMegaSwapSellDataEmpty(dcaArgs.megaSwapSellData), "Invalid paraswapArgs.");

		address user = ordersById[id].user;
		IERC20 tokenIn = IERC20(ordersById[id].tokenIn);
		IERC20 tokenOut = IERC20(ordersById[id].tokenOut);
		uint256	fees = ordersById[id].amountIn / 100;

		if (!isSimpleDataEmpty(dcaArgs.simpleData)) {
			dcaArgs.simpleData.beneficiary = payable(address(user));
			dcaArgs.simpleData.toToken = ordersById[id].tokenOut;
			dcaArgs.simpleData.fromToken = ordersById[id].tokenIn;
			dcaArgs.simpleData.fromAmount = ordersById[id].amountIn - fees;
		} else if (!isSellDataEmpty(dcaArgs.sellData)) {
			dcaArgs.sellData.beneficiary = payable(address(user));
			dcaArgs.sellData.fromToken = ordersById[id].tokenIn;
			dcaArgs.sellData.fromAmount = ordersById[id].amountIn - fees;
		} else if (!isMegaSwapSellDataEmpty(dcaArgs.megaSwapSellData)) {
			dcaArgs.megaSwapSellData.beneficiary = payable(address(user));
			dcaArgs.megaSwapSellData.fromToken = ordersById[id].tokenIn;
			dcaArgs.megaSwapSellData.fromAmount = ordersById[id].amountIn - fees;
		}

		uint256 balanceBefore = tokenOut.balanceOf(user);
		ordersById[id].totalExecutions += 1;
		ordersById[id].totalAmountIn += ordersById[id].amountIn - fees;
        SpiritDcaApprover(ordersById[id].approver).executeOrder();
		ordersById[id].lastExecution = block.timestamp;
		
		tokenIn.transfer(address(tresory), fees);
		tokenIn.approve(address(proxy), ordersById[id].amountIn - fees);
		if (!isSimpleDataEmpty(dcaArgs.simpleData)) {
			proxy.simpleSwap(dcaArgs.simpleData);
		} else if (!isSellDataEmpty(dcaArgs.sellData)) {
			proxy.multiSwap(dcaArgs.sellData);
		} else if (!isMegaSwapSellDataEmpty(dcaArgs.megaSwapSellData)) {
			proxy.megaSwap(dcaArgs.megaSwapSellData);
		}
		
		uint256 balanceAfter = tokenOut.balanceOf(user);
		require(balanceAfter - balanceBefore >= ordersById[id].amountOutMin, 'Too little received.');
		ordersById[id].totalAmountOut += balanceAfter - balanceBefore;

		emit OrderExecuted(user, id, ordersById[id].tokenIn, ordersById[id].tokenOut, ordersById[id].amountIn - fees, ordersById[id].amountOutMin, ordersById[id].period);
	}
	
	function executeOrder(uint256 id, uint256 amountTokenInGelatoFees, paraswapArgs memory dcaArgs, paraswapArgs memory ftmSwapArgs) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].stopped == false, 'Order is stopped.');
		require(block.timestamp - ordersById[id].lastExecution >= ordersById[id].period, 'Period not elapsed.');
		require(ERC20(ordersById[id].tokenIn).balanceOf(ordersById[id].user) >= ordersById[id].amountIn, 'Not enough balance.');
		uint256 initialAmountIn = ordersById[id].amountIn;
		bool isFtmSwap = !isSimpleDataEmpty(ftmSwapArgs.simpleData) || !isSellDataEmpty(ftmSwapArgs.sellData) || !isMegaSwapSellDataEmpty(ftmSwapArgs.megaSwapSellData);

		if (isFtmSwap)
		{
			uint256 gelatoFees = 0;

			require(amountTokenInGelatoFees < ordersById[id].amountIn, 'amountTokenInGelatoFees too high.');
			ordersById[id].amountIn -= amountTokenInGelatoFees;

			if (!isSimpleDataEmpty(ftmSwapArgs.simpleData))
				gelatoFees = ftmSwapArgs.simpleData.fromAmount;
			else if (!isSellDataEmpty(ftmSwapArgs.sellData))
				gelatoFees = ftmSwapArgs.sellData.fromAmount;
			else if (!isMegaSwapSellDataEmpty(ftmSwapArgs.megaSwapSellData))
				gelatoFees = ftmSwapArgs.megaSwapSellData.fromAmount;

			SpiritDcaApprover(ordersById[id].approver).transferGelatoFees(gelatoFees);
			ERC20(ordersById[id].tokenIn).approve(address(proxy), gelatoFees);

			if (!isSimpleDataEmpty(ftmSwapArgs.simpleData))
				proxy.simpleSwap(ftmSwapArgs.simpleData);
			else if (!isSellDataEmpty(ftmSwapArgs.sellData))
				proxy.multiSwap(ftmSwapArgs.sellData);
			else if (!isMegaSwapSellDataEmpty(ftmSwapArgs.megaSwapSellData))
				proxy.megaSwap(ftmSwapArgs.megaSwapSellData);
		}

		_executeOrder(id, dcaArgs);

		if (isFtmSwap)
		{
			ordersById[id].amountIn = initialAmountIn;
			(uint256 fee, address feeToken) = _getFeeDetails();

        	_transfer(fee, feeToken);
			emit GelatoFeesCheck(fee, feeToken);
		}
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
	
	function createTask(uint256 id) private {
		require(ordersById[id].taskId == bytes32(""), 'Task already created.');

		bytes memory execData = abi.encode(
			Strings.toHexString(uint256(uint160(address(this))), 20),						//dca
			id,																				//id
			Strings.toHexString((uint256(uint160(ordersById[id].user))), 20),				//userAddress						
			Strings.toHexString((uint256(uint160(ordersById[id].tokenIn))), 20),			//srcToken
			Strings.toHexString((uint256(uint160(ordersById[id].tokenOut))), 20),			//destToken
			Strings.toString(ERC20(ordersById[id].tokenIn).decimals()),						//srcDecimals
			Strings.toString(ERC20(ordersById[id].tokenOut).decimals()),					//destDecimals
			Strings.toString((ordersById[id].amountIn / 100) * 99),							//amount
			"250",																			//network
			"spiritswap",																	//partner
			"false",																		//otherExchangePrices
			"15"																			//maxImpact
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
			scriptCID,
			execData
		);
		moduleData.args[2] = _timeTriggerModuleArg(
			uint128(ordersById[id].lastExecution), 
			uint128(ordersById[id].period + 180) * 1000
		);

		bytes32 taskId = _createTask(address(this), execData, moduleData, 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
	
		ordersById[id].taskId = taskId;
		
		emit GelatoTaskCreated(taskId);
	}

	function cancelTask(uint256 id) private {
        require(ordersById[id].taskId != bytes32(""), "Task not started.");
		bytes32 taskId = ordersById[id].taskId;
		ordersById[id].taskId = bytes32("");

        _cancelTask(taskId);

		emit GelatoTaskCancelled(taskId);
    }

	function createOrder(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period, paraswapArgs memory dcaArgs) public {
		require(period >= 1 days, 'Period must be greater than 1 day.');
		require(amountIn > 0, 'AmountIn must be greater than 0.');
		require(tokenIn != tokenOut, 'TokenOut must be different.');
		require(tokenIn != address(0), 'Invalid tokenIn.');
		require(tokenOut != address(0), 'Invalid tokenOut.');

        address approver = address(new SpiritDcaApprover{salt: bytes32(ordersCount)}(ordersCount, msg.sender, tokenIn));
		Order memory order = Order(msg.sender, tokenIn, tokenOut, amountIn, amountOutMin, period, 0, 0, 0, 0, block.timestamp, false, approver, 0);
		ordersById[ordersCount] = order;
		idByAddress[msg.sender].push(ordersCount);
		ordersCount++;

		_executeOrder(getOrdersCountTotal() - 1, dcaArgs);
		createTask(getOrdersCountTotal() - 1);

		emit OrderCreated(msg.sender, getOrdersCountTotal() - 1, tokenIn, tokenOut, amountIn, amountOutMin, period);
	}

	function editOrder(uint256 id, uint256 amountIn, uint256 amountOutMin, uint256 period, paraswapArgs memory dcaArgs) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].user == msg.sender, 'Order does not belong to user.');
		require(period >= 1 days, 'Period must be greater than 1 day.');
		require(amountIn > 0, 'AmountIn must be greater than 0.');
		require(amountOutMin >= 0, 'AmountOutMin must be greater or equal 0.');

		cancelTask(id);
		ordersById[id].amountIn = amountIn;
		ordersById[id].amountOutMin = amountOutMin;
		ordersById[id].period = period;
		if (block.timestamp - ordersById[id].lastExecution >= ordersById[id].period) 
			_executeOrder(id, dcaArgs);
		createTask(id);

		emit OrderEdited(msg.sender, id, ordersById[id].tokenIn, ordersById[id].tokenOut, amountIn, amountOutMin, period);
	}

	function stopOrder(uint256 id) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].user == msg.sender, 'Order does not belong to user.');
		require(ordersById[id].stopped == false, 'Order is already stopped.');

		ordersById[id].stopped = true;
		cancelTask(id);

		emit OrderStopped(msg.sender, id);
	}
	
	function restartOrder(uint256 id, paraswapArgs memory dcaArgs) public {
		require(id < getOrdersCountTotal(), 'Order does not exist.');
		require(ordersById[id].user == msg.sender, 'Order does not belong to user.');
		require(ordersById[id].stopped == true, 'Order is not stopped.');

		ordersById[id].stopped = false;
		if (block.timestamp - ordersById[id].lastExecution >= ordersById[id].period) {
			_executeOrder(id, dcaArgs);
		}
		createTask(id);

		emit OrderRestarted(msg.sender, id);
	}

	function editTresory(address _tresory) public onlyOwner {
		tresory = IERC20(_tresory);

		emit EditedTresory(_tresory);
	}

	function editScriptCID(string memory _cid) public onlyOwner {
		scriptCID = _cid;
	}


	function withdrawFees() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No FTM to withdraw");

		payable(address(tresory)).transfer(balance);

		emit WithdrawnFees(address(tresory), balance);
    }

	receive() external payable {}
}
