.PHONY: all html website clean

all: html

html: luabingen.html

website: luabingen.html

luabingen.html: luabingen.md
	cp ~/work/site_template/style.css style.css
	pandoc $< --standalone --metadata title="luabingen" --toc --css=style.css -o $@

clean:
	rm -f luabingen.html style.css
