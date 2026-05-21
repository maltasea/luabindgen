.PHONY: all test html website clean

# `test` is the default — it's portable across machines and reports
# concrete pass/fail counts. `make html` (and the `all` alias for it)
# builds the website but depends on a machine-local stylesheet at
# ~/work/site_template/style.css; that's a maintainer's target, not
# something a fresh checkout should hit by default.
all: test

test:
	@sh tests/run.sh

html: index.html
website: index.html

STYLE_TEMPLATE = $(HOME)/work/site_template/style.css

index.html: README.md
	@test -f $(STYLE_TEMPLATE) || { \
	  echo "make html requires $(STYLE_TEMPLATE)"; \
	  echo "(maintainer-only target — needs the site_template stylesheet)"; \
	  exit 1; }
	cp $(STYLE_TEMPLATE) style.css
	pandoc $< --standalone --metadata title="luabindgen" --toc --css=style.css -o $@
	perl -i -0777 -pe 's{(<nav id="TOC".*?</nav>)\s*(<h1[^>]*>.*?</h1>)}{$$2\n$$1}s' $@

clean:
	rm -f index.html style.css
