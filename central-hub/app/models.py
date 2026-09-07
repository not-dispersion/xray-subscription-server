from datetime import datetime, timezone
from sqlalchemy import (
    func,
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import relationship

from app.database import Base


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    surname = Column(String, nullable=False, index=True)

    link = relationship(
        "Link",
        back_populates="user",
        uselist=False,
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class Link(Base):
    __tablename__ = "links"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        unique=True,
        nullable=False,
    )
    token = Column(String, unique=True, nullable=False, index=True)
    device_limit = Column(Integer, default=1, nullable=False)

    user = relationship("User", back_populates="link")
    node_mappings = relationship(
        "LinkNode",
        back_populates="link",
        cascade="all, delete-orphan",
        lazy="selectin",
    )
    devices = relationship(
        "Device",
        back_populates="link",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class Node(Base):
    __tablename__ = "nodes"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, nullable=False)
    api_url = Column(String, nullable=False)
    is_active = Column(Boolean, default=True, nullable=False)

    link_mappings = relationship(
        "LinkNode",
        back_populates="node",
        cascade="all, delete-orphan",
    )


class LinkNode(Base):
    __tablename__ = "link_nodes"

    id = Column(Integer, primary_key=True, index=True)
    link_id = Column(Integer,ForeignKey("links.id", ondelete="CASCADE"), nullable=False)
    node_id = Column(Integer, ForeignKey("nodes.id", ondelete="CASCADE"), nullable=False)   
    key = Column(String, nullable=False)

    __table_args__ = (
        UniqueConstraint("link_id", "node_id", name="uq_link_node"),
    )

    link = relationship("Link", back_populates="node_mappings")
    node = relationship("Node", back_populates="link_mappings", lazy="joined")


class Device(Base):
    __tablename__ = "devices"

    id = Column(Integer, primary_key=True, index=True)
    link_id = Column(Integer, ForeignKey("links.id", ondelete="CASCADE"), nullable=False)
    device_identifier = Column(String, nullable=False, index=True)
    device_os = Column(String, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    __table_args__ = (
        UniqueConstraint("link_id", "device_identifier", name="uq_link_device"),
    )

    link = relationship("Link", back_populates="devices")