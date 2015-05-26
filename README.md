# MOOSE Autocomplete Package

Context sensitive Atom.io autocompletion for [MOOSE Framework](http://mooseframework.org) input files. Install
[autocomplete-plus](https://github.com/atom-community/autocomplete-plus) before
installing this package.

## Block names
Block names are suggested when the autocompletion is triggered with the cursor inside a ```[]``` pair of square brackets.

![Block name completion](http://i.imgur.com/wGxI8t7.gif)

## Parameter names
Parameter names are suggested when the autocompletion is triggered within a block on an empty line. The autocompletion is sensitive to the type (or default type) of the current block!

![Parameter name completion](http://i.imgur.com/9IwJuqt.gif)

## Parameter values
Parameter values are suggested (MooseEnums, bools) if the cursor is behind an ```=``` equal sign that is preceeded by a valid parameter name for the current bock.

![Parameter value completion](http://i.imgur.com/VNztT7O.gif)

### Variable completion
Parameters taking variable names (Aux or Non-linear) get a list of currently defined variable names.

![Variable name completion](http://i.imgur.com/U7MrRBs.gif)

### Type parameter completion
Valid block types are suggested. Further parameter suggestions in the current block depend on the choice of the bock type.

![Block type completion](http://i.imgur.com/tyFuFgp.gif)
