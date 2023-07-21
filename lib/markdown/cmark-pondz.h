#include "cmark-gfm.h"
#include "cmark-gfm-extension_api.h"

extern void cmark_gfm_core_extensions_ensure_registered();
cmark_syntax_extension *table;
cmark_syntax_extension *autolink;
cmark_syntax_extension *strikethrough;

void init() {
	cmark_gfm_core_extensions_ensure_registered();
	table = cmark_find_syntax_extension("table");
	autolink = cmark_find_syntax_extension("autolink");
	strikethrough = cmark_find_syntax_extension("strikethrough");
}

char *markdown_to_html(const char *text, size_t len) {
	cmark_parser *parser = cmark_parser_new(0);
	cmark_parser_attach_syntax_extension(parser, table);
	cmark_parser_attach_syntax_extension(parser, autolink);
	cmark_parser_attach_syntax_extension(parser, strikethrough);

	cmark_parser_feed(parser, text, len);
	cmark_node *node = cmark_parser_finish(parser);

	char *html = cmark_render_html(node, CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE | CMARK_OPT_GITHUB_PRE_LANG, cmark_parser_get_syntax_extensions(parser));
	cmark_parser_free(parser);
	return html;
}
