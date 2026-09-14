@tool
extends EditorPlugin

## Editor entry point for dot-entity. It registers nothing, and that is correct.
##
## [b]Everything in this addon is a plain object a game owns.[/b] A [DotEntityTable] is
## not a [Node] and not an autoload: a table belongs to one game, and a process running
## a server and a client -- or two servers in one editor session -- has two of them. It
## has no tick and nothing to place, so there is no "Add Node" entry to offer and no
## inspector type to register.
##
## The plugin exists so the addon can be enabled alongside the others and so
## [code]plugin.cfg[/code] has somewhere to point. Enabling or disabling it never
## changes the behaviour of code that already references these classes by
## [code]class_name[/code].


func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	pass
