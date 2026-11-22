# Parse a flowseal *.bat file and pick the best "general" rules.
# Output (tab separated):
#   TCP<TAB>--dpi-desync=...
#   QUIC<TAB>--filter-udp=443 --dpi-desync=...
# Flowseal puts each rule on its own long line, so no continuation joining is needed.

BEGIN { tcp_score = 0; quic_score = 0; tcp = ""; quic = "" }

{
	line = $0
	sub(/\r$/, "", line)
	sub(/\^[ \t]*$/, "", line)
	process(line)
}

END {
	print tcp "\t" quic
}

function process(s,   sc) {
	if (s !~ /--dpi-desync=/) return

	# QUIC / UDP-443 rules
	if (s ~ /--filter-udp=/ || (s ~ /--filter-l7=quic/ && s !~ /--filter-tcp=/)) {
		if (s ~ /--dpi-desync-fake-quic/ || s ~ /--filter-l7=quic/) {
			sc = 0
			if (s ~ /--hostlist=[^ ]*list-general/) sc = 3
			else if (s ~ /--hostlist=/) sc = 2
			else if (s ~ /--ipset=/) sc = 1
			if (sc > quic_score) { quic_score = sc; quic = s }
		}
		return
	}

	# TCP rules that cover both 80 and 443
	if (s !~ /--filter-tcp=/) return
	if (s ~ /%GameFilterTCP%/) return
	if (s !~ /--filter-tcp=[^ ]*80,443/ && s !~ /--filter-tcp=[^ ]*443,80/) return

	sc = 0
	if (s ~ /--hostlist=[^ ]*list-general/) sc = 3
	else if (s ~ /--hostlist=/) sc = 2
	else if (s ~ /--ipset=/) sc = 1
	else sc = 1

	if (sc > tcp_score) { tcp_score = sc; tcp = s }
}
