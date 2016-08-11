#Webpacking NQP

You need to install
[webpack](http://webpack.github.io/docs/tutorials/getting-started/). With
your version of node installed,

	npm install webpack -g

	
And then use

	npm install src/vm/js/nqp-loader src/vm/js/nqp-runtime.

For increased awesomeness we use webpack-dev-server and
webpack-reload-plugin so you need to install those.

	npm install webpack-dev-server webpack-reload-plugin

You can just install it all with

	npm install . 

Afterwards

	webpack

Should bundle up example.nqp into bundle.js, which is loaded by index.html.

If you run:

$ webpack-dev-server --progress --colors -d

A webserver will startup at localhost:8080 and example.nqp will be automatically reloaded and recompiled when you change it.


