import React from 'react';
import { Canvas } from '@react-three/fiber';
import { defaultContent, parseTextToTree } from './text';
import WordTree3D from './WordTree3D';

export default ({text=defaultContent}) => {
  return (
    <>
      <Canvas camera={{ position: [0, 10, 10], fov: 50 }}>
        <ambientLight color={'white'} intensity={0.5} />
        <pointLight position={[10, 10, 10]} />
        <WordTree3D tree={parseTextToTree(text.join('\n'))} />
        <OrbitControls enablePan={true} enableZoom={true} enableRotate={true} />
        <FlyControls movementSpeed={50} rollSpeed={0.0} dragToLook={true} />
      </Canvas>
    </>
  );
};

