package tree_sitter_zortex_test

import (
	"testing"

	tree_sitter "github.com/tree-sitter/go-tree-sitter"
	tree_sitter_zortex "github.com/tree-sitter/tree-sitter-zortex/bindings/go"
)

func TestCanLoadGrammar(t *testing.T) {
	language := tree_sitter.NewLanguage(tree_sitter_zortex.Language())
	if language == nil {
		t.Errorf("Error loading Zortex grammar")
	}
}
