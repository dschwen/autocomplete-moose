# MOOSE Autocomplete Package

Context sensitive Atom.io autocompletion for [MOOSE Framework](http://mooseframework.org) input files. Install
[autocomplete-plus](https://github.com/atom-community/autocomplete-plus) before
installing this package.

## Block names
Block names are suggested when the autocompletion is triggered with the cursor inside a ```[]``` pair of square brackets.

## Parameter names
Parameter names are suggested when the autocompletion is triggered within a block on an empty line.

## Parameter values
Parameter values are suggested (MooseEnums) if the cursor is behind an ```=``` equal sign that is preceeded by a valid parameter name for the current bock.
