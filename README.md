# crypto-trade-bot

This is a collection of scripts used in my trade playground.

# kucoin.sh
Read the code.
It tries to buy in the current sell price and put a order at some profit percent above the actual price. Of course there is no garantee of profit.
In other hand it try to sell at the current buy price and put a order to buy in lower price.

In some moment it will reach a limit of orders at least for on side, sell or buy.


Sometimes it wins, sometimes lose... 

Use it at your own risk...

# technical tips
To generate a local benchmark use:
strace -o trace -c -Ttt bash kucoin.sh

The read function is used to avoid subshells, this improves time and memory.

Sometimes APIs returns values in scientific notation, eg 0E-718 that is not supported by bc. In this case you can replace ${value/[eE]-//10^} and pass it to bc.
