import React, { useRef, useState } from 'react';
import { Line, Html, Text } from '@react-three/drei';
import { useFrame } from '@react-three/fiber';
import { useDrag } from '@use-gesture/react';
import ReactMarkdown from 'react-markdown';
import { initMarkdown } from '../markdown';
const fontFile = 'https://raw.githubusercontent.com/mrdoob/three.js/master/examples/fonts/helvetiker_bold.typeface.json'

const HoverBox = ({ position, size, setHovered }) => {
  return (
    <mesh
      position={position}
      onPointerOver={(e) => {
        e.stopPropagation();
        setHovered(true);
      }}
      onPointerOut={() => setHovered(false)}
    >
      <planeGeometry args={size} />
      <meshBasicMaterial visible={false} />
    </mesh>
  );
};

const Description = ({ description, position }) => (
  <Html
    position={position}
    transform occlude
    style={{ pointerEvents: 'none' }}
  >
    <div
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
  position = { x: 0, y: 0 },
  spaceBetweenLayers = 2,
}) => {
  const { x, y } = position;
  const radius = spaceBetweenLayers * (depth + 1); // Adjust radius for each layer
  const angleIncrement = (2 * Math.PI) / (children.length || 1);

  const [hovered, setHovered] = useState(false);
  const md = initMarkdown();
  const descriptionMarkdown = md?.render(description);

  // Calculate positions for children nodes
  const childPositions = children.map((_, index) => {
    const angle = angleIncrement * index;
    return {
      x: x + radius * Math.cos(angle),
      y: y + radius * Math.sin(angle),
    };
  });

  // Render lines to children
  const linesToChildren = childPositions.map((childPos, index) => (
    <Line
      key={index}
      points={[
        [x, y, 0],
        [childPos.x, childPos.y, 0],
      ]}
      lineWidth={1}
      color="white"
    />
  ));

  return (
    <group position={[x, y, 0]}>
      {linesToChildren}
      <Text
        color={hovered ? 'gray' : 'white'}
        anchorX="center"
        anchorY="middle"
        fontSize={depth === 0 ? 0.5 : 0.3} // Font size based on depth
        onPointerOver={(e) => {
          e.stopPropagation();
          setHovered(true);
        }}
        onPointerOut={() => setHovered(false)}
      >
        {name}
      </Text>
      <HoverBox
        position={[0, 0, 0]}
        size={[1, 1]} // Size of the hover area, adjust as needed
        setHovered={setHovered}
      />
      {hovered && (
        <Description
          description={descriptionMarkdown}
          position={[0, -0.5, 0]} // Adjust position based on text size and desired offset
        />
      )}
      {children.map((child, index) => (
        <WordNode
          key={child.name}
          name={child.name}
          description={child.description}
          children={child.children}
          depth={depth + 1}
          position={childPositions[index]}
          spaceBetweenLayers={spaceBetweenLayers}
        />
      ))}
    </group>
  );
};

export default ({ tree }) => {
  return <WordNode key={tree.name} name={tree.name} children={tree.children} />;
};
