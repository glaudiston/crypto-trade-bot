#!/bin/bash
#
# Writen by glaudistong at gmail dot com
#
# Depends on:
# - kucoin api v1
# - gnu bash
# - gnu coreutils (cut, date, base64)
# - openssl ( with sha256 and hmac support )
# - curl
# - gnu bc - Arbitrary Calculator
# - jq - json parser - https://stedolan.github.io/jq
#

tendency="${1^^}"
echo "Working on tendency: ${tendency:-AUTO}";
host='https://api.kucoin.com';
endpoint_user='/v1/user/info'; # API endpoint
endpoint_order_list='/v1/order/active-map';
endpoint_order_nano='/v1/order';
endpoint_tick='/v1/open/tick';
endpoint_btc_balance="/v1/account/BTC/balance";
endpoint_xrb_balance="/v1/account/XRB/balance";
# The kucoin.conf file need to contain:
# secret='YOUR_SECRET_HERE'; #The secret assigned when the API created
# api_key='YOUR_API_KEY_HERE';
. kucoin.conf

# using read to avoid subshells
# when using this technique remember 
# that read only read the first line
read linesize < <(tput cols);
read BL < <(echo -en "\r$(yes " " | head -n${linesize} | tr -d "\n")\r");
function do_call()
{
	method="${1:-GET}";
	data="${2}";
	success="false";
	while [ "$success" != "true" ];
	do
		read -N13 nonce < <( date +%s%N );
		str_for_sign="${endpoint}/${nonce}/${query_string}";
		# echo "DBG: $str_for_sign $data" 1>&2
		read signature < <(echo -n "${str_for_sign}" | base64 -w0 | openssl sha256 -hmac "$secret" | cut -d" " -f2);
		result=$(curl -s \
			-X $method \
			-H "KC-API-KEY: ${api_key}" \
			-H "KC-API-NONCE: ${nonce}" \
			-H "KC-API-SIGNATURE: ${signature}" \
			-d "$data" \
			"${host}${endpoint}?${query_string}" );
		read success < <( jq -r .success <<< "$result" );
		if [ "$success" != "true" ]; then
			read code < <( jq -r '.code' <<< "$result" );
			read msg < <( jq -r '.msg' <<< "$result" );
			echo -e "\t$code\t$msg\t$method\t$str_for_sign\t$result" >&2;
			sleep 1;
		fi
	done;
	echo "$result";
};
# kucoin has a hard limit of 50 orders each side (buy,sell)
# is healthy to limit bets to a lower count limit
order_count_limit=40;

function list_my_orders() {
	endpoint="${endpoint_order_list}";
	query_string="";
	my_orders="$(do_call)";

	read sell_count < <(echo "$my_orders" | jq -r ".data.SELL | length" );
	read buy_count < <(echo "$my_orders" | jq -r ".data.BUY | length" );
	remain_sell_orders=$(( ${order_count_limit} - sell_count ));
	remain_buy_orders=$(( ${order_count_limit} - buy_count ));
}

function get_user_info()
{
	endpoint="${endpoint_user}";
	user_info="$(do_call)";
	user_name=$(echo "$user_info" | jq -r .data.name);
	user_email=$(echo "$user_info" | jq -r .data.email);
	[ "$user_name" == "" ] && user_name="${user_email/@*/}" && user_name="${user_name^}"
}

function get_nano_data()
{
	endpoint="${endpoint_tick}";
	query_string="symbol=XRB-BTC";
	last_tick="$(do_call)";
	read cur_price < <(echo "$last_tick" | jq -r .data.lastDealPrice);
	read cur_buy_price < <(echo "$last_tick" | jq -r .data.buy);
	read cur_sell_price < <(echo "$last_tick" | jq -r .data.sell);
	read fee_rate < <(echo "$last_tick" | jq -r .data.feeRate);
}

function get_my_btc_balance()
{
	endpoint="$endpoint_btc_balance";
	query_string="";
	btc_balance_data="$(do_call)"
	read btc_balance_free < <(echo "$btc_balance_data" | jq -r .data.balance);
	read btc_balance_freeze < <(echo "$btc_balance_data" | jq -r .data.freezeBalance);
	# remove scientific precision, not supported by bc;
	read btc_balance_freeze < <(bc <<< "scale=8;${btc_balance_freeze/[eE]-//10^}");
	read btc_balance < <( bc <<< "scale=8; ${btc_balance_free/[eE]-//10^} + ${btc_balance_freeze/[eE]-//10^}" );
	# echo "BTC balance: $btc_balance";
}

function get_my_nano_balance()
{
	endpoint="$endpoint_xrb_balance";
	query_string="";
	nano_balance_data=$(do_call);
	read nano_balance_free < <( echo "$nano_balance_data" | jq -r .data.balance);
	read nano_balance_freeze < <( echo "$nano_balance_data" | jq -r .data.freezeBalance);
	nano_balance=$( bc <<< "scale=8; $nano_balance_free + $nano_balance_freeze" )
	# echo "Nano balance: $nano_balance"
}

# TODO: function to group current order book using less orders

get_user_info;
echo "Hi ${user_name}";

list_my_orders;
echo "- orders are sells: ${sell_count}, buys: ${buy_count}";
get_my_btc_balance;
echo "- balance: BTC: ${btc_balance}";
get_my_nano_balance;
echo "- Nano: ${nano_balance}";
get_nano_data;
read all_balance < <( bc <<< "scale=8; ${btc_balance} + ${nano_balance} * ${cur_price}" )
echo "- all: all_balance: ${all_balance}";

while sleep 1;
do
{
	get_nano_data;

	if [ "${last_price}" != "${cur_price}" ]; then
	{
		remain_sell_orders=$(( ${order_count_limit} - sell_count ));
		remain_buy_orders=$(( ${order_count_limit} - buy_count ));

		if [ "${sell_count}" -ge "${order_count_limit}" -o "${buy_count}" -ge "${order_count_limit}" ]; then
		{
			echo -en "${BL}Order count limit reached, waiting (SELL: $sell_count, BUY: $buy_count, Nano: ${cur_price})...";
			list_my_orders;
			continue;
		}
		fi;

		get_my_btc_balance;
		get_my_nano_balance;
		amount_btc_buy=$( bc <<< "scale=8; ( $btc_balance_free / 2 ) / ( ${remain_buy_orders}  )" );
		# The precision of XRB is 6
		amount_sell=$( bc <<< "scale=6; ( $nano_balance_free / 2 ) / ( ${remain_sell_orders} ) " );

		echo -ne "${BL}Nano price changed: ${cur_price} ...";

		if [ "$1" == "" ]; then
			# if user not specified any tendency,
			# lets try to detect current tendency
			threshold_order=$(( order_count_limit * 20 / 100 ))
			if [ "${remain_buy_orders}" -lt "${threshold_order}" -a "${remain_sell_orders}" -lt "${threshold_order}" ]; then
				# if both, i don't know
				# the order book is overloaded and we need to take a break
				echo -en "${BL} Nano: ${cur_price}. Unable to detect tendency, Too much orders in both sides, waiting fulfil orders (SELL: $sell_count, BUY: $buy_count)...";
				list_my_orders;
				continue
			elif [ "${remain_sell_orders}" -lt "${threshold_order}" -a "${tendency}" != "DOWN" ]; then
				# if remain sell orders count is lower than 20% of order count limit
				# then tendency is down
				tendency="DOWN";
				echo "New tendency ${tendency}";
			elif [ "${remain_buy_orders}" -lt "${threshold_order}" -a "${tendency}" != "UP" ]; then
				# if remain buy orders count is lower than 20% of order count limit
				# then tendency is up
				tendency="UP";
				echo "New tendency ${tendency}";
			fi
		fi;

		ensure_order=0;
		if [ "$tendency" != "DOWN" ]; then
		{
			if [ "${remain_sell_orders}" -le 0 ]; then
			{
				echo -en "${BL}Sem ordens de venda restantes, aguardando liberar (SELL: $sell_count, BUY: $buy_count)...";
				list_my_orders;
			}
			else
			{
				# se acreditamos na alta:
				if [ "$( bc <<<  "scale=8; $btc_balance_free > 0" )" == "1" ]; then
				{
					# se tem btc disponivel,
					# compra no novo preço atual
					endpoint="$endpoint_order_nano";
					read amount < <( bc <<< "scale=6; $amount_btc_buy / $cur_sell_price" );
					if [ "$( bc <<< "scale=6; $amount < 0.1" )" == "1" ]; then
					{
						# XRB min buy amount
						echo -en "${BL}Quantidade de compra de XRB abaixo do mínimo... aguardando liberar fundos (BTC: $btc_balance_free, XRB: $nano_balance_free)...";
						list_my_orders;
					}
					elif [ "${ensure_order}" == "1" -a "$(bc <<< "scale=6; ${amount} > ${nano_balance_free}" )" == "1" ]; then
					{
						# XRB min buy amount
						echo -en "${BL}Quantidade de XRB livre para ordem insuficiente para agendar a venda de ${amount} XRB após a compra. Aguardando liberar fundos (BTC: $btc_balance_free, XRB: $nano_balance_free)...";
						list_my_orders;
					}
					else
					{
						gain_percent="0.5";
						query_string="amount=${amount}&price=${cur_sell_price}&symbol=XRB-BTC&type=BUY";
						buy_resp=$(do_call POST "${query_string}");
						# e coloca uma ordem de venda acima em um preço que tenha lucro, 
						# deixando uma pequena reserva em nano a cada ordem
						gain_sell_price="$( bc <<< "scale=8;$cur_sell_price * ( 1 + ${gain_percent}/100)" )"
						endpoint="$endpoint_order_nano";
						read amount < <( bc <<< "scale=6; $amount * .995" )
						query_string="amount=${amount}&price=$gain_sell_price&symbol=XRB-BTC&type=SELL";
						sell_resp=$(do_call POST "${query_string}");
						list_my_orders
						echo -e "${BL}Nano: ${cur_price}, sells: ${sell_count}, buys: ${buy_count}, Comprou $amount Nano a ${cur_sell_price}, agendou a venda a ${gain_sell_price}";
					}
					fi;
				}
				else
				{
					echo -e "${BL}No BTC free to use."
				}
				fi;
			}
			fi;
		}
		fi;

		if [ "$tendency" != "UP" ]; then
		{
			if [ "${remain_buy_orders}" -le 0 ]; then
			{
				echo -en "${BL}Sem ordens de compra restantes, aguardando liberar (SELL: $sell_count, BUY: $buy_count)...";
				list_my_orders;
			}
			else
			{
				# se acreditamos na baixa
				if [ "$( bc <<<  "scale=8; ${nano_balance_free} > 0" )" == "1" ]; then
				{
					# se tem nano disponivel, vende no preço atual
					# vende no novo preço atual
					endpoint="$endpoint_order_nano";
					amount="$amount_sell";
					if [ "$( bc <<< "scale=6; ${amount} < 0.1" )" == "1" ]; then
					{
						# XRB min buy amount
						echo -en "${BL}Quantidade de compra de XRB abaixo do mínimo... aguardando liberar fundos (BTC: $btc_balance_free, XRB: $nano_balance_free)...";
						list_my_orders;
					}
					elif [ "$ensure_order" == "1" -a "$(bc <<< "scale=6; ( ${amount} * ${cur_buy_price} ) > ${btc_balance_free}" )" == "1" ]; then
					{
						# XRB min buy amount
						echo -en "${BL}Quantidade de BTC livre para ordem insuficiente para agendar a compra de ${amount} XRB após a venda. Aguardando liberar fundos (BTC: $btc_balance_free, XRB: $nano_balance_free)...";
						list_my_orders;
					}
					else
					{
						#sell_and_buy ${amount} ${cur_buy_price} ${gain}
						gain_percent="0.5";
						query_string="amount=${amount}&price=${cur_buy_price}&symbol=XRB-BTC&type=SELL";
						sell_resp=$(do_call POST "${query_string}");
						#TODO ensure the full sell
						# e coloca uma ordem de compra acima em um preço que tenha lucro, 
						# deixando uma pequena reserva em btc a cada ordem
						read gain_sell_price < <( bc <<< "scale=8;$cur_buy_price * ( 1 - ${gain_percent}/100 )" );
						endpoint="$endpoint_order_nano";
						query_string="amount=${amount}&price=$gain_sell_price&symbol=XRB-BTC&type=BUY";
						buy_resp=$(do_call POST "${query_string}");
						list_my_orders
						echo -e "${BL}Nano: ${cur_price}, sells: ${sell_count}, buys: ${buy_count}, Vendeu $amount Nano a ${cur_buy_price}, agendou a compra a ${gain_sell_price}";
					}
					fi;
				}
				else
				{
					echo -e "${BL}No Nano free to use."
				}
				fi;
			}
			fi;
		}
		fi;
		last_price="$cur_price";
		echo -n "Waiting for next price change..."
	}
	fi;
};
done;

