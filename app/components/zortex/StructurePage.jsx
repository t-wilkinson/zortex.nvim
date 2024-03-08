import React, { createContext, useRef, forwardRef, useContext, useMemo, useLayoutEffect, useState, useEffect } from 'react'
import * as THREE from 'three';
import { useFrame, useThree } from '@react-three/fiber';
import { useDrag } from '@use-gesture/react';
import { Text } from '@react-three/drei';

const context = createContext()

const Circle = forwardRef(({ children, opacity = 1, radius = 0.05, segments = 32, color = '#ff1050', ...props }, ref) => (
  <mesh ref={ref} {...props}>
    <circleGeometry args={[radius, segments]} />
    <meshBasicMaterial transparent={opacity < 1} opacity={opacity} color={color} />
    {children}
  </mesh>
))

export const Node = forwardRef(({ color = 'black', name, connectedTo = [], position = [0, 0, 0], ...props }, ref) => {
  const set = useContext(context)
  const { size, camera } = useThree()
  const [pos, setPos] = useState(() => new THREE.Vector3(...position))
  const state = useMemo(() => ({ position: pos, connectedTo }), [pos, connectedTo])

  // Register this node on mount, unregister on unmount
  useLayoutEffect(() => {
    set((nodes) => [...nodes, state])
    return () => void set((nodes) => nodes.filter((n) => n !== state))
  }, [state, pos])

  // Drag n drop, hover
  const [hovered, setHovered] = useState(false)

  useEffect(() => void (document.body.style.cursor = hovered ? 'grab' : 'auto'), [hovered])

  const bind = useDrag(({ down, xy: [x, y] }) => {
    document.body.style.cursor = down ? 'grabbing' : 'grab'
    setPos(new THREE.Vector3((x / size.width) * 2 - 1, -(y / size.height) * 2 + 1, 0).unproject(camera).multiply({ x: 1, y: 1, z: 0 }).clone())
  })

  return (
    <Circle ref={ref} {...bind()} opacity={0.2} radius={0.5} color={color} position={pos} {...props}>
      <Circle
        radius={0.25}
        position={[0, 0, 0.1]}
        onPointerOver={() => setHovered(true)}
        onPointerOut={() => setHovered(false)}
        color={hovered ? '#ff1050' : color}>
        <Text position={[0, 0, 1]} fontSize={0.25}>
          {name}
        </Text>
      </Circle>
    </Circle>
  )
})

const Nodes = ({ children }) => {
  const group = useRef()
  const [nodes, set] = useState([])
  const lines = useMemo(() => {
    const lines = []
    for (let node of nodes)
      node.connectedTo
        .map((ref) => [node.position, ref.current.position])
        .forEach(([start, end]) => lines.push({ start: start.clone().add({ x: 0.35, y: 0, z: 0 }), end: end.clone().add({ x: -0.35, y: 0, z: 0 }) }))
    return lines
  }, [nodes])

  useFrame((_, delta) => group.current.children.forEach((group) => (group.children[0].material.uniforms.dashOffset.value -= delta * 10)))

  return (
    <context.Provider value={set}>
      <group ref={group}>
        {lines.map((line, index) => (
          <group>
            <QuadraticBezierLine key={index + 'a'} {...line} color="white" dashed dashScale={50} gapSize={20} />
            <QuadraticBezierLine key={index + 'b'} {...line} color="white" lineWidth={0.5} transparent opacity={0.1} />
          </group>
        ))}
      </group>
      {children}
      {lines.map(({ start, end }, index) => (
        <group key={index} position-z={1}>
          <Circle position={start} />
          <Circle position={end} />
        </group>
      ))}
    </context.Provider>
  )
}

const Tree = ({ data }) => {
  const { size } = useThree()

  const [nodes, setNodes] = useState([])

  useLayoutEffect(() => {
    const nodeMap = new Map()
    const set = (nodes) => {
      nodes.forEach((node) => {
        const ref = React.createRef()
        nodeMap.set(node.text, ref)
        return {
          ...node,
          connectedTo: node.children.map((child) => nodeMap.get(child.text)),
          ref,
        }
      })
      return nodes
    }

    const add = (nodes) => nodes.forEach((node) => setNodes((nodes) => [...nodes, node]))

    add(set([data]))
  }, [data])

  console.log(nodes)

  return (
    <Nodes>
      {nodes.map((node) => (
        <Node key={node.text} {...node} />
      ))}
    </Nodes>
  )
}

function textToTree(text) {
    // Split the text by lines
    let lines = text.split("\n");
    let root = { text: "root", children: [] };
    let currentParent = root;
    let indent = 0;

    // Iterate through each line
    for (let line of lines) {
        // Remove leading and trailing whitespaces
        line = line.trim();

        // Skip empty lines
        if (line === "") {
            continue;
        }

        // Count the indent level by the number of dashes
        let newIndent = line.match(/^\s*-/)?.[0].length || 0;

        // If the new indent level is smaller than the current indent level,
        // find the parent at the correct level
        if (newIndent < indent) {
            let diff = indent - newIndent;
            while (diff > 0) {
                currentParent = currentParent.parent;
                diff--;
            }
        }

        // Create a new node for the current line
        let node = { text: line, children: [] };

        // Add the node as a child of the current parent and update the parent
        currentParent.children.push(node);
        node.parent = currentParent;

        // Update the current indent level
        indent = newIndent;
    }

    // Return the root node
    return root;
}

const App = () => {
  return <Tree data={defaultTree} />;
};

export default App;

const defaultTree = {
  "text": "root",
  "children": [
    {
      "text": "The arts",
      "children": [
        {
          "text": "Art",
          "children": [
            {
              "text": "Design",
              "children": []
            },
            {
              "text": "Harmony",
              "children": []
            },
            {
              "text": "Origami",
              "children": []
            },
            {
              "text": "Performance",
              "children": []
            }
          ]
        },
        {
          "text": "Music",
          "children": [
            {
              "text": "Composition",
              "children": []
            },
            {
              "text": "Performance",
              "children": []
            },
            {
              "text": "Piano",
              "children": []
            },
            {
              "text": "Gaspard de la Nuit",
              "children": []
            },
            {
              "text": "Music theory",
              "children": []
            },
            {
              "text": "Harmony (music)",
              "children": []
            }
          ]
        }
      ]
    },
    {
      "text": "Cognitive science",
      "children": [
        {
          "text": "Linguistics",
          "children": []
        },
        {
          "text": "Cognition",
          "children": [
            {
              "text": "Logic",
              "children": []
            },
            {
              "text": "Agent",
              "children": [
                {
                  "text": "Power",
                  "children": []
                },
                {
                  "text": "Focus",
                  "children": []
                },
                {
                  "text": "Consciousness",
                  "children": []
                }
              ]
            },
            {
              "text": "Knowledge",
              "children": [
                {
                  "text": "Encoding",
                  "children": []
                },
                {
                  "text": "Model",
                  "children": []
                },
                {
                  "text": "How to learn",
                  "children": []
                },
                {
                  "text": "How to research",
                  "children": []
                },
                {
                  "text": "Knowledge management",
                  "children": []
                },
                {
                  "text": "Art of memory",
                  "children": []
                },
                {
                  "text": "Knowledge contexts",
                  "children": []
                },
                {
                  "text": "Reasoning",
                  "children": []
                },
                {
                  "text": "Epistemology",
                  "children": []
                },
                {
                  "text": "Ontology",
                  "children": []
                },
                {
                  "text": "Knowledge representation",
                  "children": []
                },
                {
                  "text": "Homotopy type theory",
                  "children": []
                }
              ]
            },
            {
              "text": "Artificial intelligence",
              "children": [
                {
                  "text": "Learning algorithm",
                  "children": []
                },
                {
                  "text": "Machine learning",
                  "children": []
                },
                {
                  "text": "Reinforcement learning",
                  "children": []
                },
                {
                  "text": "Deep learning",
                  "children": []
                },
                {
                  "text": "Artificial neural network",
                  "children": []
                },
                {
                  "text": "Dangers of artificial intelligence",
                  "children": []
                },
                {
                  "text": "Artificial general intelligence",
                  "children": []
                },
                {
                  "text": "Model architectures",
                  "children": []
                },
                {
                  "text": "Model performance and scalability",
                  "children": []
                },
                {
                  "text": "Cloud technologies",
                  "children": []
                },
                {
                  "text": "MLOps",
                  "children": []
                }
              ]
            },
            {
              "text": "Neuroscience",
              "children": [
                {
                  "text": "Cell biology",
                  "children": []
                },
                {
                  "text": "Neuron",
                  "children": []
                },
                {
                  "text": "Nervous system",
                  "children": [
                    {
                      "text": "Brain",
                      "children": []
                    },
                    {
                      "text": "Thalamus",
                      "children": []
                    },
                    {
                      "text": "Cerebral cortex",
                      "children": [
                        {
                          "text": "Neocortex",
                          "children": []
                        },
                        {
                          "text": "Cortical column",
                          "children": []
                        }
                      ]
                    }
                  ]
                },
                {
                  "text": "Cell signaling",
                  "children": [
                    {
                      "text": "Neurotransmitter",
                      "children": []
                    },
                    {
                      "text": "Synapse",
                      "children": []
                    },
                    {
                      "text": "Membrane potential",
                      "children": []
                    }
                  ]
                }
              ]
            },
            {
              "text": "Psychology",
              "children": [
                {
                  "text": "Mental health",
                  "children": [
                    {
                      "text": "Mental disorders",
                      "children": []
                    },
                    {
                      "text": "Addiction",
                      "children": []
                    },
                    {
                      "text": "Depression",
                      "children": []
                    }
                  ]
                },
                {
                  "text": "Jungian psychology",
                  "children": []
                },
                {
                  "text": "Cognitive development",
                  "children": []
                },
                {
                  "text": "Creativity",
                  "children": []
                },
                {
                  "text": "Intelligence",
                  "children": []
                },
                {
                  "text": "Thousand brains theory",
                  "children": []
                }
              ]
            },
            {
              "text": "Philosophy",
              "children": [
                {
                  "text": "Religion",
                  "children": []
                },
                {
                  "text": "Ethics",
                  "children": []
                },
                {
                  "text": "Knowledge",
                  "children": []
                },
                {
                  "text": "Virtues",
                  "children": []
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}


// Given the following tree data structure, give me code that will modify the following code to display a node for each text item using react-three-fiber. Have children be displayed radially around their parents in a 2D space.
// {"text":"Neuroscience","children":[{"text":"Cellbiology","children":[]},{"text":"Neuron","children":[]},{"text":"Nervoussystem","children":[{"text":"Cerebralcortex","children":[{"text":"Neocortex","children":[]},{"text":"Corticalcolumn","children":[]}]}]},{"text":"Cellsignaling","children":[{"text":"Neurotransmitter","children":[]},{"text":"Synapse","children":[]},{"text":"Membranepotential","children":[]}]}]},

// import React, { createContext, forwardRef, useContext, useMemo, useLayoutEffect, useState, useEffect } from 'react'
// import * as THREE from 'three';
// import { useFrame, useThree } from '@react-three/fiber';
// import { useDrag } from '@use-gesture/react';
// import { Text } from '@react-three/drei';

// const context = createContext()

// const Circle = forwardRef(({ children, opacity = 1, radius = 0.05, segments = 32, color = '#ff1050', ...props }, ref) => (
// <mesh ref={ref} {...props}>
// <circleGeometry args={[radius, segments]} />
// <meshBasicMaterial transparent={opacity < 1} opacity={opacity} color={color} />
// {children}

// ))

// export const Node = forwardRef(({ color = 'black', name, connectedTo = [], position = [0, 0, 0], ...props }, ref) => {
// const set = useContext(context)
// const { size, camera } = useThree()
// const [pos, setPos] = useState(() => new THREE.Vector3(...position))
// const state = useMemo(() => ({ position: pos, connectedTo }), [pos, connectedTo])

// // Register this node on mount, unregister on unmount
// useLayoutEffect(() => {
// set((nodes) => [...nodes, state])
// return () => void set((nodes) => nodes.filter((n) => n !== state))
// }, [state, pos])

// // Drag n drop, hover
// const [hovered, setHovered] = useState(false)

// useEffect(() => void (document.body.style.cursor = hovered ? 'grab' : 'auto'), [hovered])

// const bind = useDrag(({ down, xy: [x, y] }) => {
// document.body.style.cursor = down ? 'grabbing' : 'grab'
// setPos(new THREE.Vector3((x / size.width) * 2 - 1, -(y / size.height) * 2 + 1, 0).unproject(camera).multiply({ x: 1, y: 1, z: 0 }).clone())
// })

// return (
// <Circle ref={ref} {...bind()} opacity={0.2} radius={0.5} color={color} position={pos} {...props}>
// <Circle
// radius={0.25}
// position={[0, 0, 0.1]}
// onPointerOver={() => setHovered(true)}
// onPointerOut={() => setHovered(false)}
// color={hovered ? '#ff1050' : color}>
// <Text position={[0, 0, 1]} fontSize={0.25}>
// {name}



// )
// })

// const Nodes = ({ children }) => {
// const group = useRef()
// const [nodes, set] = useState([])
// const lines = useMemo(() => {
// const lines = []
// for (let node of nodes)
// node.connectedTo
// .map((ref) => [node.position, ref.current.position])
// .forEach(([start, end]) => lines.push({ start: start.clone().add({ x: 0.35, y: 0, z: 0 }), end: end.clone().add({ x: -0.35, y: 0, z: 0 }) }))
// return lines
// }, [nodes])

// useFrame((_, delta) => group.current.children.forEach((group) => (group.children[0].material.uniforms.dashOffset.value -= delta * 10)))

// return (
// <context.Provider value={set}>

// {lines.map((line, index) => (

// <QuadraticBezierLine key={index + 'a'} {...line} color="white" dashed dashScale={50} gapSize={20} />
// <QuadraticBezierLine key={index + 'b'} {...line} color="white" lineWidth={0.5} transparent opacity={0.1} />

// ))}

// {children}
// {lines.map(({ start, end }, index) => (


// ))}
// </context.Provider>
// )
// }
