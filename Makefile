.PHONY: t
t:
	zig build test --summary all -freference-trace

.PHONY: s
s:
	zig build run -freference-trace -- --root /tmp/wallz/ --cors '*' --log_http
