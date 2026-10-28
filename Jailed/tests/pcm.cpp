#include "../TimbrePCM.h"
#include <cassert>
#include <cstring>
#include <limits>
#include <cstdio>
int main(){
 using namespace timbre_pcm;
 for(unsigned bits:{16u,24u,32u})for(unsigned bytes:{2u,3u,4u}){
  if(!supported(bits,bytes))continue;
  for(bool high:{false,true})for(float x:{-2.f,-1.f,-0.5f,0.f,0.5f,1.f,2.f}){
   uint8_t guarded[8];std::memset(guarded,0xa5,sizeof guarded);
   write(guarded+2,x,bits,bytes,high);float y=read(guarded+2,bits,bytes,high);
   const double epsilon=1./std::ldexp(1.,bits-1)+1e-7;
   assert(std::abs(y-std::clamp(double(x),-1.,1.))<=epsilon);
   assert(guarded[0]==0xa5&&guarded[1]==0xa5&&guarded[2+bytes]==0xa5);
  }
 }
 uint8_t p[4];write(p,-0.5f,24,3,false);assert(p[0]==0&&p[1]==0&&p[2]==0xc0);
 write(p,-0.5f,24,4,true);assert(p[0]==0&&p[1]==0&&p[2]==0&&p[3]==0xc0);
 write(p,0.5f,24,4,false);assert(p[0]==0&&p[1]==0&&p[2]==0x40&&p[3]==0);
 write(p,std::numeric_limits<float>::quiet_NaN(),24,3,false);assert(read(p,24,3,false)==0);
 assert(!supported(20,3)&&!supported(24,2)&&!supported(32,3));
 puts("PCM: signed 16/24/32-bit, packed/padded alignment, clipping, NaN and buffer guards passed");
}
