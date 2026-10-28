#pragma once
#include <cstdint>
#include <cmath>
#include <algorithm>
namespace timbre_pcm {
inline bool supported(unsigned bits,unsigned bytes){return (bits==16&&bytes==2)||(bits==24&&(bytes==3||bytes==4))||(bits==32&&bytes==4);}
inline float read(const void *data,unsigned bits,unsigned bytes,bool high){
    const auto *p=static_cast<const uint8_t *>(data);uint32_t raw=0;
    for(unsigned i=0;i<bytes;i++)raw|=uint32_t(p[i])<<(8*i);
    if(high&&bits==24&&bytes==4)raw>>=8;
    const uint32_t mask=bits==32?UINT32_MAX:((uint32_t(1)<<bits)-1);raw&=mask;
    int64_t value=raw;if(raw&(uint32_t(1)<<(bits-1)))value-=int64_t(1)<<bits;
    return float(double(value)/std::ldexp(1.,bits-1));
}
inline void write(void *data,float input,unsigned bits,unsigned bytes,bool high){
    const double scale=std::ldexp(1.,bits-1);
    double x=std::isfinite(input)?input:0.;
    int64_t value=std::llround(std::clamp(x,-1.,(scale-1)/scale)*scale);
    uint32_t raw=uint32_t(value);
    if(bits<32)raw&=(uint32_t(1)<<bits)-1;
    if(high&&bits==24&&bytes==4)raw<<=8;
    auto *p=static_cast<uint8_t *>(data);for(unsigned i=0;i<bytes;i++)p[i]=uint8_t(raw>>(8*i));
}
}
