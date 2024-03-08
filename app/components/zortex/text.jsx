import * as THREE from 'three'
import { FontLoader } from 'three/addons/loaders/FontLoader'
import { useLoader, mesh } from '@react-three/fiber'

// We'll take the structure as the root tree, create a tree for each article, then attach the article where relevant
// We'll need a faster way to search the tree for word of choice
// For now assume we are taking in a graph. Later, we can find out how exactly we want to convert text to graph
const getTreeData = (s) => {
  const indent = s.match(/^\s+/);
  const title = s.match(/- (.*)$/);
  // const title = s.match(/- \[?([^]]*)?$/)[1];
  if (!indent || !title) {
    return null
  }
  return [indent[0].length, title[1]];
}

export const treeToGraph = (lines) => {
  const tree = {
    name: 'root',
    children: []
  };
  let parent

  const ptrs = [[0, tree]]; // stack
  for (let line of lines){
    const treeData = getTreeData(line);
    if (!treeData) {
      continue
    }
    const [indent, name] = treeData

    while (ptrs.length && ptrs[ptrs.length-1][0] >= indent)
      ptrs.pop();
    parent = ptrs.length ? ptrs[ptrs.length-1][1] : tree;
    const obj = {name: name, children: []};
    parent.children.push(obj);
    ptrs.push([indent, obj]);
  }

  return tree;
}

export function parseTextToTree(text) {
  const lines = text.split('\n');

  // Helper function to create a new node
  function createNode(name, tags = []) {
    return { name, tags, children: [], description: '' };
  }

  // Initialize root node and tags
  const rootNode = createNode('Algebraic geometry');
  let currentNode = rootNode;
  let currentTags = [];
  let currentDescription = [];

  // Helper function to process descriptions
  function processDescription(list) {
    return list.map(line => (line.match(/^\w/)) ? `- ${line}` : line).join('\n');
  }

  for (const line of lines) {
    if (line.startsWith('@@')) {
      // Root node
      currentNode.name = line.substring(2).trim();
    } else if (line.startsWith('@')) {
      // Tags
      currentTags = line.substring(1).trim().split(/\s*,\s*/);
    } else if (line.startsWith('#')) {
      // Heading found, create new node
      if (currentNode !== rootNode) {
        // Add current description to current node
        currentNode.description = processDescription(currentDescription);
        currentDescription = [];
      }
      // Determine the depth of the heading
      const depth = line.lastIndexOf('#') + 1;
      const name = line.substring(depth).trim();
      const newNode = createNode(name, currentTags);

      // Find the correct parent for the new node based on depth
      let parent = rootNode;
      if (depth > 1) {
        let tempNode = currentNode;
        while (tempNode && depth <= tempNode.depth) {
          tempNode = tempNode.parent;
        }
        parent = tempNode || rootNode;
      }

      // Set parent-child relationship
      newNode.depth = depth;
      newNode.parent = parent;
      parent.children.push(newNode);

      // Set current node to the new node
      currentNode = newNode;
    } else {
      // Description text
      currentDescription.push(line);
    }
  }

  // Add leftover description to the last node
  if (currentDescription.length > 0) {
    currentNode.description = processDescription(currentDescription);
  }

  // Clean up temporary properties like depth and parent
  function cleanupNode(node) {
    delete node.depth;
    delete node.parent;
    node.tags = [...new Set(node.tags)]; // Remove duplicate tags
    node.children.forEach(cleanupNode); // Recursively clean up children
  }

  cleanupNode(rootNode);

  return rootNode;
}

export function parseWikipediaTextToTree(text) {

  const lines = text.split('\n');

  // Helper function to create a new node
  function createNode(name, tags = []) {
    return { name, tags, children: [], description: '' };
  }

  // Initialize root node and tags
  const rootNode = createNode('Page Title');
  let currentNode = rootNode;
  let currentTags = [];
  let currentContent = [];

  for (const line of lines) {
    if (line.startsWith('==')) {
      // Heading found, create new node
      if (currentNode !== rootNode) {
        // Add current content to current node
        currentNode.description = currentContent.join('\n');
        currentContent = [];
      }
      const depth = (line.match(/=/g) || []).length / 2; // Determine the depth of the heading
      const name = line.replace(/=/g, '').trim();
      const newNode = createNode(name, currentTags);

      // Find the correct parent for the new node based on depth
      let parent = rootNode;
      let tempNode = currentNode;
      while (tempNode && depth <= tempNode.depth) {
        tempNode = tempNode.parent;
      }
      parent = tempNode || rootNode;

      // Set parent-child relationship
      newNode.depth = depth;
      newNode.parent = parent;
      parent.children.push(newNode);

      // Set current node to the new node
      currentNode = newNode;
    } else {
      // Content text
      currentContent.push(line);
    }
  }

  // Add leftover content to the last node
  if (currentContent.length > 0) {
    currentNode.description = currentContent.join('\n');
  }

  // Clean up temporary properties like depth and parent
  function cleanupNode(node) {
    delete node.depth;
    delete node.parent;
    node.tags = [...new Set(node.tags)]; // Remove duplicate tags
    node.children.forEach(cleanupNode); // Recursively clean up children
  }

  cleanupNode(rootNode);

  return rootNode;
}

export const defaultContent = `@@Algebraic geometry
@Mathematics

What is algebraic geometry? It is the study of algebraic varieties and in particular, to classify all up to isomorphism.

# Concepts
Algebraic varieties

Scheme: allows studying algebraic ways similar to differential geometry
Stack
Etale space
Commutative rings
Commutative ring space

Dimensions
Regular functions
Rational maps
Nonsingular varieties
Degree of a projective variety

# Commutative ring

## Ideal
An ideal $α$ of a ring $A$ which is a subset of $A$ which is closed with respect to all elements of $A$, that is, $Aα ⊆ α$. This induces a quotient group $A/α$.

## Prime ideal
A prime ideal is a prime if $xy ∈ ρ ⇒ x∈ρ or y∈ρ$.
Can you "recover" the prime number if $1x∈ρ$
$ρ is prime ⇔ A/ρ is an integral domain$

In a sense, the smallest ring that represents some idea of a non-reducible number (there does not exist a number that multiplies into it). It is a ring built from some generating number, that generating is the "prime" being unreducible.

# Affine varieties
Affine n-space
Polynomial ring

# Sheaf
We begin with the notion of a sheaf $F$ on a topological space $X$. Sheafs capture the idea of nice functions defined on local data. These functions $f|_v$ can be restricted to open subsets $V \subset U$ and then recovered through collating restrictions $V_i$ to a covering of $U$. This restriction-collation description applies not just to functions, but structures defined locally. This description allows defining structure on an underlying space that may not contain that structure globally. Being able to take a restriction-collation approach to structure, one can avoid emergent properties where relationships can induce additional structure or complexity.

Alternatively one can observe sets $F_x$ which are sections of a bundle associating points to associated neighborhoods of points. The topology of $X$ can be recovering through pasting together the open sets $F_x$.

Let us first recall that topology was initially a generalization of real analysis and serves to define continuous functions, requiring a definition for limits.

Now we give the definition:
Restriction: if $f$ is continuous, then $f|_v$ for $V \subset U$ is continuous.
Collation: for any open covering $U_i$ of $U$, the restrictions $f|_{U_i} = f_i$ agree on all overlaps $U_i \cap U_j$ such that $f_i x = f_j x$ for all $x \elem U_i \cap U_j$.

Alexander Grothendieck`;

// I currently have react-three-fiber code that takes a markdown like format and parses it into a tree where headings are parents of subheadings. This is the code:
//
// function parseTextToTree(text) {
// const lines = text.split('\n');
//
// // Helper function to create a new node
// function createNode(name, tags = []) {
// return { name, tags, children: [], description: '' };
// }
//
// // Initialize root node and tags
// const rootNode = createNode('Algebraic geometry');
// let currentNode = rootNode;
// let currentTags = [];
// let currentDescription = [];
//
// // Helper function to process descriptions
// function processDescription(list) {
// return list.map(line => (line.match(/^\w/)) ? - ${line} : line).join('\n');
// }
//
// for (const line of lines) {
// if (line.startsWith('@@')) {
// // Root node
// currentNode.name = line.substring(2).trim();
// } else if (line.startsWith('@')) {
// // Tags
// currentTags = line.substring(1).trim().split(/\s*,\s*/);
// } else if (line.startsWith('#')) {
// // Heading found, create new node
// if (currentNode !== rootNode) {
// // Add current description to current node
// currentNode.description = processDescription(currentDescription);
// currentDescription = [];
// }
// // Determine the depth of the heading
// const depth = line.lastIndexOf('#') + 1;
// const name = line.substring(depth).trim();
// const newNode = createNode(name, currentTags);
//
//   // Find the correct parent for the new node based on depth
//   let parent = rootNode;
//   if (depth > 1) {
//     let tempNode = currentNode;
//     while (tempNode && depth <= tempNode.depth) {
//       tempNode = tempNode.parent;
//     }
//     parent = tempNode || rootNode;
//   }
//
//   // Set parent-child relationship
//   newNode.depth = depth;
//   newNode.parent = parent;
//   parent.children.push(newNode);
//
//   // Set current node to the new node
//   currentNode = newNode;
// } else {
//   // Description text
//   currentDescription.push(line);
// }
//
// }
//
// // Add leftover description to the last node
// if (currentDescription.length > 0) {
// currentNode.description = processDescription(currentDescription);
// }
//
// // Clean up temporary properties like depth and parent
// function cleanupNode(node) {
// delete node.depth;
// delete node.parent;
// node.tags = [...new Set(node.tags)]; // Remove duplicate tags
// node.children.forEach(cleanupNode); // Recursively clean up children
// }
//
// cleanupNode(rootNode);
//
// return rootNode;
// }
//
// const text = `@@Algebraic geometry
// @Mathematics
//
// What is algebraic geometry? It is the study of algebraic varieties and in particular, to classify all up to isomorphism.
// Concepts
//
// Algebraic varieties
//
// Scheme: allows studying algebraic ways similar to differential geometry
// Stack
// Etale space
// Commutative rings
// Commutative ring space
//
// Dimensions
// Regular functions
// Rational maps
// Nonsingular varieties
// Degree of a projective variety
// Commutative ring
// Ideal
//
// An ideal $α$ of a ring $A$ which is a subset of $A$ which is closed with respect to all elements of $A$, that is, $Aα ⊆ α$. This induces a quotient group $A/α$.
// Prime ideal
//
// A prime ideal is a prime if $xy ∈ ρ ⇒ x∈ρ or y∈ρ$.
// Can you "recover" the prime number if $1x∈ρ$
// $ρ is prime ⇔ A/ρ is an integral domain$
//
// In a sense, the smallest ring that represents some idea of a non-reducible number (there does not exist a number that multiplies into it). It is a ring built from some generating number, that generating is the "prime" being unreducible.
// Affine varieties
//
// Affine n-space
// Polynomial ring
// Sheaf
//
// We begin with the notion of a sheaf $F$ on a topological space $X$. Sheafs capture the idea of nice functions defined on local data. These functions $f|_v$ can be restricted to open subsets $V \subset U$ and then recovered through collating restrictions $V_i$ to a covering of $U$. This restriction-collation description applies not just to functions, but structures defined locally. This description allows defining structure on an underlying space that may not contain that structure globally. Being able to take a restriction-collation approach to structure, one can avoid emergent properties where relationships can induce additional structure or complexity.
//
// Alternatively one can observe sets $F_x$ which are sections of a bundle associating points to associated neighborhoods of points. The topology of $X$ can be recovering through pasting together the open sets $F_x$.
//
// Let us first recall that topology was initially a generalization of real analysis and serves to define continuous functions, requiring a definition for limits.
//
// Now we give the definition:
// Restriction: if $f$ is continuous, then $f|v$ for $V \subset U$ is continuous.
// Collation: for any open covering $U_i$ of $U$, the restrictions $f|{U_i} = f_i$ agree on all overlaps $U_i \cap U_j$ such that $f_i x = f_j x$ for all $x \elem U_i \cap U_j$.
//
// Alexander Grothendieck`;
//
// Could you write javascript code that will take a wikipedia link and generate a similar tree. Each node should have a description parameter and it should be formatted so that a markdown and latex parser (react-markdown, rehype-katex and remark-math).



// const defaultContent_old = `@@Test
// A@Tag1
//
// test == test
//
// - [Test]
//
// % #z-reference#general#
//
//   - Represents a change of basis or coordinates encoding the notion that the basis vectors may change as a function of position in the vector field.
//
// - Differential form
//   - Recall that compact sets can be viewed as closed and bounded sets in a topological space.
//   - For the following statements, let:
//       - $D \\subset \\mathbb{R}^k$ be a compact set
//       - $W \\subset \\mathbb{R}^k$ be a compact set and $D \\subset W$
//       - $E \\subset \\mathbb{R}^n$ be an open set
//   - If $f$ is a *$\\mathscr{C}$'-mapping* of $D$ into $\\mathbb{R}^n$ then there exists a $\\mathscr{C}$'-mapping $g$ which maps $W$ into $\\mathbb{R}^n$ such that $g(x)=f(x)$ for all $x \\in D$.
//       - One can view a $f$ as embedding a compact set in $\\mathbb{R}^n$.
//   - A *k-surface* in $E$ is a $\\mathscr{C}$'-mapping $\\phi$ from $D$ into $E$
//       - $D$ is called the parameter domain of $\\phi$
//
//   - A *differential form of order $k \\ge 1$ in $E$* (a *k-form in $E$*) is a function $\\omega$ which assigns to each $\\phi$ in $E$ a number $\\omega(\\phi) = \\int_\\phi \\omega$. $i_1, \\cdots, i_k$ range independently from 1 to $n$.
//       $$\\omega = \\sum a_{i_1} \\cdots _{i_k}(\\mathbf{x})dx_{i_1} \\wedge \\cdots \\wedge dx_{i_k}$$
//       $$\\int_\\phi \\omega = \\int_D \\sum a_{i_1} \\cdots _{i_k}(\\mathbf{\\Phi}(\\mathbf{u})) \\frac{\\partial(x_{i_1},\\cdots,x_{i_k})}{\\partial(u_1,\\cdots,u_{k})} d\\mathbf{u}$$
//       $$\\int_{\\Omega}d\\omega = \\int_{\\partial\\Omega}\\omega$$
//
// 10:20
//     - hello
//
// A.
//     - x
//     AA.
//       - x
//
// B.
//     - x
//     - x
// C.
//     CA.
//         CAA.
//             - x
//             - x
//
// D.
//     - x
//
//     DA.
//       - x
//
//
// 1. Test one
// 2. Test two
//
// - [z-source]{type=website; resource=link; title=one; ref=https://youtube.com}
// - {type=website; resource=image; title=one; ref=http://www.graphviz.org/Gallery/directed/bazel.svg}
//
// `
//
