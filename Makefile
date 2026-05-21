.PHONY: all html website test clean

all: html

html: index.html

website: index.html

test:
	@sh tests/run.sh

index.html: README.md
	cp ~/work/site_template/style.css style.css
	pandoc $< --standalone --metadata title="luabindgen" --toc --css=style.css -o $@
	perl -i -0777 -pe 's{(<nav id="TOC".*?</nav>)\s*(<h1[^>]*>.*?</h1>)}{$$2\n$$1}s' $@

clean:
	rm -f index.html style.css
