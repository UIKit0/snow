/**************************************************************************
**
**   SNOW - CS224 BROWN UNIVERSITY
**
**   scene.h
**   Authors: evjang, mliberma, taparson, wyegelwe
**   Created: 8 Apr 2014
**
**************************************************************************/

#ifndef SCENE_H
#define SCENE_H

class ParticleSystem;
class Renderable;
class SceneNode;
class SceneNodeIterator;

class Scene
{

public:

    Scene();
    virtual ~Scene();

    virtual void render();

    SceneNode* root() { return m_root; }

    SceneNodeIterator begin() const;

private:

    SceneNode *m_root;

    void setupLights();

};

#endif // SCENE_H
