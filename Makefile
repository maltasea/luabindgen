.PHONY: all html website clean

all: html

html: index.html

website: index.html

index.html: README.md
	cp ~/work/site_template/style.css style.css
	pandoc $< --standalone --metadata title="luabindgen" --toc --css=style.css -o $@

clean:
	rm -f index.html style.css
