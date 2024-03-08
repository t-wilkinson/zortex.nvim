import React, { createContext, createRef, useMemo, useRef, useState, useContext, forwardRef, useEffect } from 'react';
import * as THREE from 'three';
import { QuadraticBezierLine, Line, FlyControls, OrbitControls, Html, Text } from '@react-three/drei';
import { Canvas, useLoader, extend, useFrame, useThree } from '@react-three/fiber';
import { FontLoader } from 'three/examples/jsm/loaders/FontLoader';
import { TextGeometry } from 'three/examples/jsm/geometries/TextGeometry';
import { useDrag } from '@use-gesture/react'
import ReactMarkdown from 'react-markdown';
import rehypeKatex from 'rehype-katex';
import remarkMath from 'remark-math';
import { defaultContent, treeToGraph, parseTextToTree, parseWikipediaTextToTree} from './text'
import { initMarkdown } from '../markdown';

const fontFile = 'https://raw.githubusercontent.com/mrdoob/three.js/master/examples/fonts/helvetiker_bold.typeface.json'

extend({ TextGeometry });

const TextMesh = ({ name, font, textSize, textHeight, meshRef, hovered, centerOffset, rotation }) => (
  <mesh ref={meshRef} position={centerOffset} rotation={rotation}>
    <textGeometry args={[name, { font, size: textSize, height: textHeight }]} />
    <meshStandardMaterial attach="material" color={hovered ? "gray" : "white"} />
  </mesh>
);

const HoverBox = ({ bboxSize, setHovered }) => {
  const bboxMeshRef = useRef(); // Separate ref for the invisible bounding box mesh

  return (
    <mesh
      ref={bboxMeshRef}
      onPointerOver={(e) => {
        e.stopPropagation();
        setHovered(true);
      }}
      onPointerOut={() => setHovered(false)}
      scale={[1, 1, 1]} // Ensure the mesh is not scaled down
    >
      <boxGeometry args={bboxSize} />
      <meshBasicMaterial attach="material" opacity={0} transparent={true} />
    </mesh>
  );
};

const Description = ({ description, bboxSize }) => (
  <Html
    position={[0, bboxSize[1] / 2 + 1, 0]}
    transform occlude billboard
  >
    <section
      className="markdown-body"
      style={{ background: 'white', padding: '10px', borderRadius: '5px' }}
      dangerouslySetInnerHTML={{
        __html: description,
      }}
    />
  </Html>
);

const WordNode = ({
  name,
  description = '',
  children,
  depth = 0,
  angle = 0,
  font,
  rootFontSize = 2, // Default base font size for root nodes
  spaceBetweenLayers = 2, // Default space between layers
}) => {
  const radius = (4 - Math.min(4, depth)) * spaceBetweenLayers + 1;
  const x = Math.cos(angle) * radius;
  const y = depth * 1.5 + 1; // Increase Y offset to provide more space between layers
  const z = Math.sin(angle) * radius;
  const childAngleIncrement = (2 * Math.PI) / (children.length || 1);

  // Adjusting the scale factor for root nodes to be larger
  const scaleFactor = depth === 0 ? rootFontSize : Math.max(0.5, rootFontSize - depth * 0.8);
  const textSize = 0.5 * scaleFactor;
  const textHeight = 0.2 * scaleFactor;

  // TODO: cannot reuse same markdown instance. This doesn't seem efficient.
  const md = initMarkdown()
  const descriptionMarkdown = md?.render(description)

  const meshRef = useRef();
  const [hovered, setHovered] = useState(false);
  const [bboxSize, setBboxSize] = useState([0, 0, 0]);
  useEffect(() => {
    if (meshRef.current) {
      const bbox = new THREE.Box3().setFromObject(meshRef.current);
      const size = new THREE.Vector3();
      bbox.getSize(size);
      setBboxSize(size.toArray());
    }
  }, [meshRef, name, description]);

  const [centerOffset, setCenterOffset] = useState([0, 0, 0]);
  useEffect(() => {
    if (meshRef.current) {
      meshRef.current.geometry.computeBoundingBox();
      const bbox = meshRef.current.geometry.boundingBox;
      const offsetX = (bbox.max.x - bbox.min.x) / 2;
      const offsetY = (bbox.max.y - bbox.min.y) / 2;
      setCenterOffset([-offsetX, -offsetY, 0]);
    }
  }, [meshRef, name, description]);

  // Render lines to children
  const linesToChildren = children.map((child, index) => {
    const childRadius = (4 - Math.min(4, depth + 1)) * spaceBetweenLayers + 1;
    const childX = Math.cos(index * childAngleIncrement) * childRadius;
    const childY = (depth + 1) * 1.5 + 1;
    const childZ = Math.sin(index * childAngleIncrement) * childRadius;

    const points = [
      new THREE.Vector3(0, 0, 0), // Parent position
      new THREE.Vector3(childX, childY, childZ) // Child position
    ];

    return (
      <Line
        key={index}
        points={points}
        lineWidth={1}
        color="white"
      />
    );
  });

  return (
    <group
      position={[x, y, z]}
      rotation={[0, -angle + Math.PI * 1/2, 0]}
    >
      {linesToChildren}
      <TextMesh
        name={name}
        font={font}
        textSize={textSize}
        textHeight={textHeight}
        meshRef={meshRef}
        hovered={hovered}
        centerOffset={centerOffset}
      />
      <HoverBox bboxSize={bboxSize} setHovered={setHovered} />
      {hovered && <Description md={md} description={descriptionMarkdown} bboxSize={bboxSize} />}
      {children.map((child, index) => (
        <WordNode
          key={child.name}
          name={child.name}
          description={child.description}
          children={child.children}
          depth={depth + 1}
          angle={index * childAngleIncrement}
          font={font}
          rootFontSize={rootFontSize}
          spaceBetweenLayers={spaceBetweenLayers}
        />
      ))}
    </group>
  );
};

export default ({ tree }) => {
  const font = useLoader(FontLoader, fontFile);
  return <WordNode key={tree.name} name={tree.name} children={tree.children} font={font} />;
};
