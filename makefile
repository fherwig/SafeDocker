IMAGENAME=fherwig/safe:22.0
build: 
	docker build  -t $(IMAGENAME) .

release: 
	docker build  --no-cache -t $(IMAGENAME) .

install:
	./install.sh
