serve:
	bundle exec jekyll serve

build:
	bundle exec jekyll build

install:
	bundle install

update:
	rm -rf /tmp/_site
	cp -r _site /tmp
	git checkout master
	mv /tmp/_site/* .
